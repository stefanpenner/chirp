// HotkeyRecorder.swift — Panel for recording custom hotkey shortcuts.
// Shows a macOS-style shortcut recording field: click the rounded rectangle
// to start recording, press a key/combo, review it, then Save or Cancel.
// Uses NSVisualEffectView for glass vibrancy and system typography.

import AppKit
@preconcurrency import CoreGraphics
import SwiftUI

// MARK: - Recorder State

@MainActor
@Observable
final class HotkeyRecorderState {
    var isRecording = false
    var capturedConfig: HotkeyConfig?
    var currentLabel: String

    init(currentLabel: String) {
        self.currentLabel = currentLabel
    }

    /// Label shown in the shortcut field.
    var displayLabel: String {
        if isRecording { return "Record Shortcut" }
        if let captured = capturedConfig { return captured.label }
        return currentLabel
    }

    var canSave: Bool { capturedConfig != nil }

    func reset(label: String) {
        currentLabel = label
        isRecording = false
        capturedConfig = nil
    }
}

// MARK: - Recorder Panel

@MainActor
final class HotkeyRecorderPanel {
    private var panel: NSPanel?
    private var monitor: Any?
    private weak var appState: AppState?
    private var state: HotkeyRecorderState?
    /// Track which modifier key was pressed (for modifier-only detection).
    private var pendingModifierKeyCode: UInt16?

    init(appState: AppState) {
        self.appState = appState
    }

    func show() {
        // Keep the tap active but suppress callbacks — prevents the
        // configured hotkey from triggering the system action (emoji
        // picker, recording, etc.) while the dialog is visible.
        appState?.hotkeyManager?.suppressOnly = true
        pendingModifierKeyCode = nil

        let label = appState?.hotkeyConfig.label ?? "fn"
        if let state {
            state.reset(label: label)
        } else {
            state = HotkeyRecorderState(currentLabel: label)
        }

        if panel == nil { createPanel() }
        panel?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() {
        stopRecordingMode()
        panel?.orderOut(nil)
        appState?.hotkeyManager?.suppressOnly = false
    }

    private func save() {
        guard let config = state?.capturedConfig else { return }
        appState?.updateHotkey(config)
        close()
    }

    private func resetToFn() {
        appState?.updateHotkey(.fn)
        close()
    }

    private func clearCapture() {
        state?.capturedConfig = nil
        stopRecordingMode()
    }

    func startRecordingMode() {
        guard let state, !state.isRecording else { return }
        state.isRecording = true
        pendingModifierKeyCode = nil
        installMonitor()
    }

    func stopRecordingMode() {
        state?.isRecording = false
        removeMonitor()
    }

    private func createPanel() {
        guard let state else { return }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 180),
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false
        )
        panel.title = "Change Hotkey"
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating

        let recorder = self
        let rootView = HotkeyRecorderView(
            state: state,
            onFieldClick: { recorder.startRecordingMode() },
            onClear: { recorder.clearCapture() },
            onReset: { recorder.resetToFn() },
            onSave: { recorder.save() },
            onCancel: { recorder.close() }
        )

        let hostingView = NSHostingView(rootView: rootView)
        hostingView.translatesAutoresizingMaskIntoConstraints = false

        let vibrancy = NSVisualEffectView()
        vibrancy.material = .popover
        vibrancy.blendingMode = .behindWindow
        vibrancy.state = .active
        vibrancy.addSubview(hostingView)

        NSLayoutConstraint.activate([
            hostingView.topAnchor.constraint(equalTo: vibrancy.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: vibrancy.bottomAnchor),
            hostingView.leadingAnchor.constraint(equalTo: vibrancy.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: vibrancy.trailingAnchor),
        ])

        panel.contentView = vibrancy
        panel.center()
        self.panel = panel
    }

    // MARK: - Event monitor

    private func installMonitor() {
        removeMonitor()
        // Local event monitors always run on the main thread.
        // Extract event data (primitives) before crossing into @MainActor
        // to avoid NSEvent's non-Sendable boundary issue.
        let recorder = self
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            let eventType = event.type
            let keyCode = event.keyCode
            let mods = event.modifierFlags
            let consumed = MainActor.assumeIsolated {
                recorder.handleEvent(type: eventType, keyCode: keyCode, modifierFlags: mods)
            }
            return consumed ? nil : event
        }
    }

    private func removeMonitor() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    /// Returns true if the event should be consumed (suppressed).
    private func handleEvent(
        type: NSEvent.EventType, keyCode: UInt16, modifierFlags: NSEvent.ModifierFlags
    ) -> Bool {
        switch type {
        case .keyDown:
            // ESC exits recording mode without capturing
            if keyCode == 0x35 {
                stopRecordingMode()
                return true
            }

            // Capture regular key + modifiers
            let nsMods = modifierFlags.intersection(.deviceIndependentFlagsMask)
                .subtracting([.capsLock, .numericPad, .function])
            let cgMods = HotkeyConfig.nsModsToCGFlags(nsMods)
            let label = HotkeyConfig.buildLabel(
                keyCode: keyCode, isModifier: false, modifiers: cgMods
            )
            let config = HotkeyConfig(
                keyCode: keyCode, isModifier: false,
                modifierMask: nil, requiredModifiers: cgMods, label: label
            )
            pendingModifierKeyCode = nil
            state?.capturedConfig = config
            stopRecordingMode()
            return true

        case .flagsChanged:
            let hasAny = !modifierFlags.intersection(
                [.command, .shift, .option, .control, .function]
            ).isEmpty

            if hasAny {
                // Modifier pressed — track the latest one
                pendingModifierKeyCode = keyCode
            } else if let mkc = pendingModifierKeyCode {
                // All modifiers released — capture as modifier-only
                guard let mask = HotkeyConfig.modifierMaskForKeyCode(mkc) else {
                    pendingModifierKeyCode = nil
                    return true
                }
                let label = HotkeyConfig.buildLabel(keyCode: mkc, isModifier: true)
                let config = HotkeyConfig(
                    keyCode: mkc, isModifier: true,
                    modifierMask: mask, requiredModifiers: [], label: label
                )
                pendingModifierKeyCode = nil
                state?.capturedConfig = config
                stopRecordingMode()
            }
            return true

        default:
            return false
        }
    }
}

// MARK: - Recorder View

private struct HotkeyRecorderView: View {
    var state: HotkeyRecorderState
    let onFieldClick: () -> Void
    let onClear: () -> Void
    let onReset: () -> Void
    let onSave: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            // Shortcut recording field
            HStack(spacing: 0) {
                Text(state.displayLabel)
                    .font(.system(
                        state.isRecording ? .body : .title3,
                        design: .rounded,
                        weight: state.isRecording ? .regular : .semibold
                    ))
                    .foregroundStyle(state.isRecording ? .secondary : .primary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .padding(.leading, 14)

                if state.capturedConfig != nil && !state.isRecording {
                    Button(action: onClear) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.body)
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, 10)
                } else {
                    Spacer().frame(width: 14)
                }
            }
            .background(
                .thinMaterial,
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(
                        state.isRecording
                            ? Color.accentColor
                            : .primary.opacity(0.08),
                        lineWidth: state.isRecording ? 2 : 0.5
                    )
            )
            .shadow(color: .black.opacity(0.06), radius: 2, y: 1)
            .contentShape(Rectangle())
            .onTapGesture { if !state.isRecording { onFieldClick() } }
            .animation(.easeInOut(duration: 0.2), value: state.isRecording)

            Text(state.isRecording
                ? "Press any key or modifier \u{b7} ESC to stop"
                : "Click to record a new shortcut")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Divider()

            HStack(spacing: 12) {
                Button("Reset to fn", action: onReset)
                Spacer()
                Button("Cancel", action: onCancel)
                Button("Save", action: onSave)
                    .disabled(!state.canSave)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 320)
    }
}
