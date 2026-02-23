// SettingsView.swift — Settings window UI.
// Provider-first layout: configure providers (name + key), then toggle features.

import AppKit
import SwiftUI

// Catppuccin Mocha palette
private let cBlue = Color(red: 0.35, green: 0.58, blue: 1.0)

// MARK: - Model Suggestions

private let openAISTTModels = ["whisper-1", "gpt-4o-mini-transcribe", "gpt-4o-transcribe"]
private let openAILLMModels = ["gpt-4o-mini", "gpt-4o", "gpt-4.1-mini", "gpt-4.1", "o4-mini"]
private let anthropicLLMModels = ["claude-sonnet-4-6-20250514", "claude-haiku-4-5-20251001", "claude-opus-4-6-20250514"]
private let googleSTTModels = ["latest_long", "latest_short"]
private let googleLLMModels = ["gemini-2.0-flash", "gemini-2.5-pro", "gemini-2.5-flash"]

private func sttModels(for proto: APIProtocol?) -> [String] {
    switch proto {
    case .openAI:    return openAISTTModels
    case .google:    return googleSTTModels
    case .anthropic, .none: return []
    }
}

private func llmModels(for proto: APIProtocol?) -> [String] {
    switch proto {
    case .openAI:    return openAILLMModels
    case .anthropic: return anthropicLLMModels
    case .google:    return googleLLMModels
    case .none:      return []
    }
}

// MARK: - ComboBoxField

struct ComboBoxField: NSViewRepresentable {
    var items: [String]
    @Binding var text: String
    var placeholder: String

    func makeNSView(context: Context) -> NSComboBox {
        let comboBox = NSComboBox()
        comboBox.usesDataSource = false
        comboBox.completes = true
        comboBox.hasVerticalScroller = true
        comboBox.placeholderString = placeholder
        comboBox.delegate = context.coordinator
        comboBox.target = context.coordinator
        comboBox.action = #selector(Coordinator.comboBoxAction(_:))
        comboBox.numberOfVisibleItems = 8
        comboBox.controlSize = .regular
        comboBox.font = .systemFont(ofSize: NSFont.systemFontSize)
        comboBox.addItems(withObjectValues: items)
        comboBox.stringValue = text
        return comboBox
    }

    func updateNSView(_ comboBox: NSComboBox, context: Context) {
        context.coordinator.parent = self
        if comboBox.stringValue != text {
            comboBox.stringValue = text
        }
        let existing = comboBox.objectValues.compactMap { $0 as? String }
        if existing != items {
            comboBox.removeAllItems()
            comboBox.addItems(withObjectValues: items)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSComboBoxDelegate, NSTextFieldDelegate {
        var parent: ComboBoxField

        init(_ parent: ComboBoxField) { self.parent = parent }

        func comboBoxSelectionDidChange(_ notification: Notification) {
            guard let comboBox = notification.object as? NSComboBox,
                  comboBox.indexOfSelectedItem >= 0,
                  let value = comboBox.objectValueOfSelectedItem as? String else { return }
            parent.text = value
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            guard let comboBox = obj.object as? NSComboBox else { return }
            parent.text = comboBox.stringValue
        }

        @objc func comboBoxAction(_ sender: NSComboBox) {
            parent.text = sender.stringValue
        }
    }
}

// MARK: - Settings View

struct SettingsView: View {
    @Bindable var appState: AppState
    @State private var selectedTab = "AI"

    var body: some View {
        TabView(selection: $selectedTab) {
            AISettingsTab(appState: appState)
                .tabItem { Label("AI", systemImage: "cpu") }
                .tag("AI")
        }
        .frame(width: 520, height: 480)
    }
}

// MARK: - AI Settings Tab

struct AISettingsTab: View {
    @Bindable var appState: AppState
    @State private var editingEndpoint: APIEndpoint?
    @State private var editingMode: AIMode?

    var body: some View {
        Form {
            // --- Providers ---
            Section("Providers") {
                ForEach(appState.aiSettings.endpoints) { endpoint in
                    EndpointRow(endpoint: endpoint) {
                        editingEndpoint = endpoint
                    } onDelete: {
                        deleteEndpoint(endpoint)
                    }
                }

                Button {
                    let newEndpoint = APIEndpoint(
                        name: "",
                        apiProtocol: .openAI,
                        baseURL: APIEndpoint.defaultBaseURL(for: .openAI)
                    )
                    editingEndpoint = newEndpoint
                } label: {
                    Label("Add Provider", systemImage: "plus")
                }
                .buttonStyle(.borderless)
            }

            // --- AI Modes ---
            Section("AI Modes") {
                ForEach(appState.aiSettings.modes) { mode in
                    AIModeRow(
                        mode: mode,
                        isActive: appState.aiSettings.activeModeID == mode.id,
                        onSelect: { appState.aiSettings.activeModeID = mode.id },
                        onEdit: { editingMode = mode },
                        onDelete: { deleteMode(mode) },
                        canDelete: appState.aiSettings.modes.count > 1
                    )
                }

                Button {
                    editingMode = AIMode(name: "")
                } label: {
                    Label("Add AI Mode", systemImage: "plus")
                }
                .buttonStyle(.borderless)
            }
        }
        .formStyle(.grouped)
        .onChange(of: appState.aiSettings) { _, newValue in
            newValue.save()
            appState.rebuildPipeline()
        }
        .sheet(item: $editingEndpoint) { endpoint in
            EndpointEditorView(
                endpoint: endpoint,
                isNew: !appState.aiSettings.endpoints.contains(where: { $0.id == endpoint.id })
            ) { saved in
                saveEndpoint(saved)
                editingEndpoint = nil
            } onCancel: {
                editingEndpoint = nil
            }
        }
        .sheet(item: $editingMode) { mode in
            AIModeEditorView(
                mode: mode,
                endpoints: appState.aiSettings.endpoints,
                isNew: !appState.aiSettings.modes.contains(where: { $0.id == mode.id })
            ) { saved in
                saveMode(saved)
                editingMode = nil
            } onCancel: {
                editingMode = nil
            }
        }
    }

    // MARK: - Endpoint helpers

    private func saveEndpoint(_ endpoint: APIEndpoint) {
        if let idx = appState.aiSettings.endpoints.firstIndex(where: { $0.id == endpoint.id }) {
            appState.aiSettings.endpoints[idx] = endpoint
        } else {
            appState.aiSettings.endpoints.append(endpoint)
        }
    }

    private func deleteEndpoint(_ endpoint: APIEndpoint) {
        appState.aiSettings.endpoints.removeAll { $0.id == endpoint.id }
        KeychainHelper.delete(account: endpoint.apiKeyRef)
        // Clear references in any mode that used this endpoint
        for i in appState.aiSettings.modes.indices {
            if appState.aiSettings.modes[i].sttEndpointID == endpoint.id {
                appState.aiSettings.modes[i].sttEndpointID = nil
            }
            if appState.aiSettings.modes[i].llmEndpointID == endpoint.id {
                appState.aiSettings.modes[i].llmEndpointID = nil
            }
        }
    }

    // MARK: - Mode helpers

    private func saveMode(_ mode: AIMode) {
        if let idx = appState.aiSettings.modes.firstIndex(where: { $0.id == mode.id }) {
            appState.aiSettings.modes[idx] = mode
        } else {
            appState.aiSettings.modes.append(mode)
            // Auto-select if it's the only mode
            if appState.aiSettings.modes.count == 1 {
                appState.aiSettings.activeModeID = mode.id
            }
        }
    }

    private func deleteMode(_ mode: AIMode) {
        guard appState.aiSettings.modes.count > 1 else { return }
        appState.aiSettings.modes.removeAll { $0.id == mode.id }
        if appState.aiSettings.activeModeID == mode.id {
            appState.aiSettings.activeModeID = appState.aiSettings.modes.first?.id
        }
    }
}

// MARK: - AI Mode Row

private struct AIModeRow: View {
    let mode: AIMode
    let isActive: Bool
    let onSelect: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void
    let canDelete: Bool

    var body: some View {
        HStack {
            Button(action: onSelect) {
                Image(systemName: isActive ? "circle.inset.filled" : "circle")
                    .foregroundStyle(isActive ? cBlue : .secondary)
                    .font(.system(size: 14))
            }
            .buttonStyle(.borderless)

            VStack(alignment: .leading, spacing: 2) {
                Text(mode.name)
                    .font(.system(size: 13, weight: .medium))
                Text(modeSummary)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Edit", action: onEdit)
                .buttonStyle(.borderless)
            if canDelete {
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
            }
        }
    }

    private var modeSummary: String {
        var parts: [String] = []
        parts.append(mode.transcriptionMode == .cloud ? "Cloud STT" : "Offline")
        switch mode.postProcessingMode {
        case .none: break
        case .regex: parts.append("Regex")
        case .llm: parts.append("Cloud LLM")
        case .regexThenLLM: parts.append("Regex + Cloud LLM")
        case .offlineLLM: parts.append("Offline LLM")
        case .regexThenOfflineLLM: parts.append("Regex + Offline LLM")
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: - AI Mode Editor

struct AIModeEditorView: View {
    @State var mode: AIMode
    let endpoints: [APIEndpoint]
    let isNew: Bool
    let onSave: (AIMode) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Name", text: $mode.name, prompt: Text("e.g. Cloud Dictation"))
                }

                Section("Transcription") {
                    Picker("Source", selection: $mode.transcriptionMode) {
                        Text("Offline").tag(TranscriptionMode.offline)
                        Text("Cloud").tag(TranscriptionMode.cloud)
                    }

                    if mode.transcriptionMode == .cloud {
                        Picker("Provider", selection: $mode.sttEndpointID) {
                            Text("None").tag(nil as UUID?)
                            ForEach(enabledEndpoints) { endpoint in
                                Text(endpoint.name).tag(endpoint.id as UUID?)
                            }
                        }
                        .padding(.leading, 20)
                        if mode.sttEndpointID != nil {
                            LabeledContent("Model") {
                                ComboBoxField(
                                    items: sttModels(for: selectedSTTEndpoint?.apiProtocol),
                                    text: sttModelBinding,
                                    placeholder: "e.g. whisper-1"
                                )
                                .frame(height: 24)
                            }
                            .padding(.leading, 20)
                        }
                    }
                }

                Section("Post-Processing") {
                    Toggle("Apply regex cleanup", isOn: regexEnabledBinding)

                    Toggle("LLM post-processing", isOn: llmEnabledBinding)

                    if isLLMEnabled {
                        Picker("Engine", selection: llmOfflineBinding) {
                            Text("Cloud").tag(false)
                            Text("Offline (T5)").tag(true)
                        }
                        .padding(.leading, 20)

                        if isLLMOffline {
                            T5ModelStatusView()
                                .padding(.leading, 20)
                        } else {
                            Picker("Provider", selection: $mode.llmEndpointID) {
                                Text("None").tag(nil as UUID?)
                                ForEach(enabledEndpoints) { endpoint in
                                    Text(endpoint.name).tag(endpoint.id as UUID?)
                                }
                            }
                            .padding(.leading, 20)
                            if mode.llmEndpointID != nil {
                                LabeledContent("Model") {
                                    ComboBoxField(
                                        items: llmModels(for: selectedLLMEndpoint?.apiProtocol),
                                        text: llmModelBinding,
                                        placeholder: "e.g. gpt-4o-mini"
                                    )
                                    .frame(height: 24)
                                }
                                .padding(.leading, 20)
                            }
                        }

                        LabeledContent("System prompt") {
                            TextEditor(text: systemPromptBinding)
                                .frame(minHeight: 60)
                                .scrollDisabled(true)
                                .font(.system(size: 12, design: .monospaced))
                        }
                        .padding(.leading, 20)
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                Button(isNew ? "Add" : "Save") { onSave(mode) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(mode.name.isEmpty)
            }
            .padding()
        }
        .frame(width: 500, height: 480)
    }

    // MARK: - Derived post-processing state

    private var isRegexEnabled: Bool {
        switch mode.postProcessingMode {
        case .regex, .regexThenLLM, .regexThenOfflineLLM: return true
        case .none, .llm, .offlineLLM: return false
        }
    }

    private var isLLMEnabled: Bool {
        switch mode.postProcessingMode {
        case .llm, .regexThenLLM, .offlineLLM, .regexThenOfflineLLM: return true
        case .none, .regex: return false
        }
    }

    private var isLLMOffline: Bool {
        switch mode.postProcessingMode {
        case .offlineLLM, .regexThenOfflineLLM: return true
        default: return false
        }
    }

    private func resolvedMode(regex: Bool, llm: Bool, offline: Bool) -> PostProcessingMode {
        switch (regex, llm, offline) {
        case (false, false, _):     return .none
        case (true,  false, _):     return .regex
        case (false, true,  false): return .llm
        case (true,  true,  false): return .regexThenLLM
        case (false, true,  true):  return .offlineLLM
        case (true,  true,  true):  return .regexThenOfflineLLM
        }
    }

    private var regexEnabledBinding: Binding<Bool> {
        Binding(
            get: { isRegexEnabled },
            set: { mode.postProcessingMode = resolvedMode(regex: $0, llm: isLLMEnabled, offline: isLLMOffline) }
        )
    }

    private var llmEnabledBinding: Binding<Bool> {
        Binding(
            get: { isLLMEnabled },
            set: { mode.postProcessingMode = resolvedMode(regex: isRegexEnabled, llm: $0, offline: isLLMOffline) }
        )
    }

    private var llmOfflineBinding: Binding<Bool> {
        Binding(
            get: { isLLMOffline },
            set: { mode.postProcessingMode = resolvedMode(regex: isRegexEnabled, llm: true, offline: $0) }
        )
    }

    // MARK: - Model bindings

    private var sttModelBinding: Binding<String> {
        Binding(
            get: { mode.sttModel ?? "" },
            set: { mode.sttModel = $0.isEmpty ? nil : $0 }
        )
    }

    private var llmModelBinding: Binding<String> {
        Binding(
            get: { mode.llmModel ?? "" },
            set: { mode.llmModel = $0.isEmpty ? nil : $0 }
        )
    }

    private var systemPromptBinding: Binding<String> {
        Binding(
            get: { mode.llmSystemPrompt ?? LLMPostProcessor.defaultSystemPrompt },
            set: { mode.llmSystemPrompt = $0 }
        )
    }

    // MARK: - Endpoint helpers

    private var enabledEndpoints: [APIEndpoint] {
        endpoints.filter { $0.isEnabled }
    }

    private var selectedSTTEndpoint: APIEndpoint? {
        guard let id = mode.sttEndpointID else { return nil }
        return endpoints.first { $0.id == id }
    }

    private var selectedLLMEndpoint: APIEndpoint? {
        guard let id = mode.llmEndpointID else { return nil }
        return endpoints.first { $0.id == id }
    }
}

// MARK: - Endpoint Row

private struct EndpointRow: View {
    let endpoint: APIEndpoint
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(endpoint.name)
                        .font(.system(size: 13, weight: .medium))
                    Text(endpoint.apiProtocol.rawValue)
                        .font(.system(size: 10, weight: .medium))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(cBlue.opacity(0.15))
                        )
                        .foregroundStyle(cBlue)
                }
            }
            Spacer()
            if !endpoint.isEnabled {
                Text("Disabled")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button("Edit", action: onEdit)
                .buttonStyle(.borderless)
            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
        }
    }
}

// MARK: - Endpoint Editor

struct EndpointEditorView: View {
    @State var endpoint: APIEndpoint
    let isNew: Bool
    let onSave: (APIEndpoint) -> Void
    let onCancel: () -> Void
    @State private var apiKeyText = ""

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Provider") {
                    TextField("Name", text: $endpoint.name, prompt: Text("e.g. Work OpenAI"))
                    Picker("Protocol", selection: $endpoint.apiProtocol) {
                        ForEach(APIProtocol.allCases, id: \.self) { proto in
                            Text(proto.rawValue).tag(proto)
                        }
                    }
                    .onChange(of: endpoint.apiProtocol) { _, newValue in
                        endpoint.baseURL = APIEndpoint.defaultBaseURL(for: newValue)
                    }
                    TextField("Base URL", text: baseURLBinding)
                    SecureField("API Key", text: $apiKeyText)
                        .onAppear {
                            if !endpoint.apiKeyRef.isEmpty {
                                apiKeyText = KeychainHelper.load(account: endpoint.apiKeyRef) ?? ""
                            }
                        }
                    Toggle("Enabled", isOn: $endpoint.isEnabled)
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                Button(isNew ? "Add" : "Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(endpoint.name.isEmpty)
            }
            .padding()
        }
        .frame(width: 460, height: 300)
    }

    private var baseURLBinding: Binding<String> {
        Binding(
            get: { endpoint.baseURL.absoluteString },
            set: { if let url = URL(string: $0) { endpoint.baseURL = url } }
        )
    }

    private func save() {
        if endpoint.apiKeyRef.isEmpty {
            endpoint.apiKeyRef = "chirp-\(endpoint.id.uuidString.prefix(8))"
        }
        if !apiKeyText.isEmpty {
            KeychainHelper.save(account: endpoint.apiKeyRef, key: apiKeyText)
        }
        onSave(endpoint)
    }
}

// MARK: - T5 Model Status

struct T5ModelStatusView: View {
    enum ModelState {
        case notDownloaded
        case downloading(Double)
        case ready
        case error(String)
    }

    @State private var modelState: ModelState = .notDownloaded
    @State private var manager: T5ModelManager?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch modelState {
            case .notDownloaded:
                HStack(spacing: 8) {
                    Image(systemName: "arrow.down.circle")
                        .foregroundStyle(.secondary)
                    Text("T5-small model not downloaded (~375 MB)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Download") { startDownload() }
                        .controlSize(.small)
                }

            case .downloading(let progress):
                HStack(spacing: 8) {
                    ProgressView(value: progress)
                        .frame(width: 120)
                    Text("\(Int(progress * 100))%")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    Button("Cancel") { cancelDownload() }
                        .controlSize(.small)
                }

            case .ready:
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("T5-small model ready")
                        .font(.caption)
                    Button(role: .destructive) { deleteModel() } label: {
                        Image(systemName: "trash")
                    }
                    .controlSize(.small)
                    .buttonStyle(.borderless)
                }

            case .error(let message):
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Retry") { startDownload() }
                        .controlSize(.small)
                }
            }
        }
        .onAppear { checkModelState() }
    }

    private func checkModelState() {
        if T5ModelManager.isAvailable {
            modelState = .ready
        } else {
            modelState = .notDownloaded
        }
    }

    private func startDownload() {
        modelState = .downloading(0)
        manager = T5ModelManager(
            onProgress: { progress in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self.modelState = .downloading(progress)
                    }
                }
            },
            onComplete: { result in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        switch result {
                        case .success:
                            self.modelState = .ready
                        case .failure(let error):
                            self.modelState = .error(error.localizedDescription)
                        }
                        self.manager = nil
                    }
                }
            }
        )
        manager?.download()
    }

    private func cancelDownload() {
        manager?.cancel()
        manager = nil
        modelState = .notDownloaded
    }

    private func deleteModel() {
        try? T5ModelManager.deleteModel()
        modelState = .notDownloaded
    }
}
