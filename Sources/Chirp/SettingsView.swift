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

            // --- Transcription ---
            Section("Transcription") {
                Picker(selection: $appState.aiSettings.transcriptionMode) {
                    Text("Offline (local)").tag(TranscriptionMode.offline)
                    Text("Cloud").tag(TranscriptionMode.cloud)
                } label: {
                    EmptyView()
                }
                .pickerStyle(.radioGroup)
                Text("Offline runs on this Mac with no internet. Cloud sends audio to an API for higher accuracy.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if appState.aiSettings.transcriptionMode == .cloud {
                    Picker("Provider", selection: $appState.aiSettings.sttEndpointID) {
                        Text("None").tag(nil as UUID?)
                        ForEach(sttCapableEndpoints) { endpoint in
                            Text(endpoint.name).tag(endpoint.id as UUID?)
                        }
                    }
                    .padding(.leading, 20)
                    if sttCapableEndpoints.isEmpty {
                        Text("Add a provider above first")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.leading, 20)
                    }
                    if appState.aiSettings.sttEndpointID != nil {
                        ComboBoxField(
                            items: sttModels(for: selectedSTTEndpoint?.apiProtocol),
                            text: sttModelBinding,
                            placeholder: "e.g. whisper-1"
                        )
                        .frame(height: 24)
                        .padding(.leading, 20)
                    }
                }
            }

            // --- Post-Processing ---
            Section("Post-Processing") {
                Picker(selection: $appState.aiSettings.postProcessingMode) {
                    Text("Regex only").tag(PostProcessingMode.regex)
                    Text("Offline LLM (T5)").tag(PostProcessingMode.offlineLLM)
                    Text("Regex then Offline LLM").tag(PostProcessingMode.regexThenOfflineLLM)
                    Text("Cloud LLM").tag(PostProcessingMode.llm)
                    Text("Regex then Cloud LLM").tag(PostProcessingMode.regexThenLLM)
                } label: {
                    EmptyView()
                }
                .pickerStyle(.radioGroup)
                Text("Regex applies pattern-based fixes. Offline LLM runs T5-small locally (no internet). Cloud LLM sends text to an API.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if appState.aiSettings.postProcessingMode == .offlineLLM ||
                   appState.aiSettings.postProcessingMode == .regexThenOfflineLLM {
                    T5ModelStatusView()
                        .padding(.leading, 20)
                }

                if appState.aiSettings.postProcessingMode == .llm ||
                   appState.aiSettings.postProcessingMode == .regexThenLLM {
                    Picker("Provider", selection: $appState.aiSettings.llmEndpointID) {
                        Text("None").tag(nil as UUID?)
                        ForEach(llmCapableEndpoints) { endpoint in
                            Text(endpoint.name).tag(endpoint.id as UUID?)
                        }
                    }
                    .padding(.leading, 20)
                    if llmCapableEndpoints.isEmpty {
                        Text("Add a provider above first")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.leading, 20)
                    }
                    if appState.aiSettings.llmEndpointID != nil {
                        ComboBoxField(
                            items: llmModels(for: selectedLLMEndpoint?.apiProtocol),
                            text: llmModelBinding,
                            placeholder: "e.g. gpt-4o-mini"
                        )
                        .frame(height: 24)
                        .padding(.leading, 20)
                        TextEditor(text: systemPromptBinding)
                            .frame(minHeight: 80)
                            .scrollDisabled(true)
                            .font(.system(size: 12, design: .monospaced))
                            .padding(.leading, 20)
                    }
                }
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
    }

    private var sttModelBinding: Binding<String> {
        Binding(
            get: { appState.aiSettings.sttModel ?? "" },
            set: { appState.aiSettings.sttModel = $0.isEmpty ? nil : $0 }
        )
    }

    private var llmModelBinding: Binding<String> {
        Binding(
            get: { appState.aiSettings.llmModel ?? "" },
            set: { appState.aiSettings.llmModel = $0.isEmpty ? nil : $0 }
        )
    }

    private var systemPromptBinding: Binding<String> {
        Binding(
            get: { appState.aiSettings.llmSystemPrompt ?? LLMPostProcessor.defaultSystemPrompt },
            set: { appState.aiSettings.llmSystemPrompt = $0 }
        )
    }

    private var sttCapableEndpoints: [APIEndpoint] {
        appState.aiSettings.endpoints.filter { $0.isEnabled }
    }

    private var llmCapableEndpoints: [APIEndpoint] {
        appState.aiSettings.endpoints.filter { $0.isEnabled }
    }

    private var selectedSTTEndpoint: APIEndpoint? {
        guard let id = appState.aiSettings.sttEndpointID else { return nil }
        return appState.aiSettings.endpoints.first { $0.id == id }
    }

    private var selectedLLMEndpoint: APIEndpoint? {
        guard let id = appState.aiSettings.llmEndpointID else { return nil }
        return appState.aiSettings.endpoints.first { $0.id == id }
    }

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
        if appState.aiSettings.sttEndpointID == endpoint.id {
            appState.aiSettings.sttEndpointID = nil
        }
        if appState.aiSettings.llmEndpointID == endpoint.id {
            appState.aiSettings.llmEndpointID = nil
        }
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
