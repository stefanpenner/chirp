// SettingsView.swift — Settings window UI.
// Provider-first layout: configure providers (name + key), then toggle features.

import SwiftUI

// Catppuccin Mocha palette
private let cBlue = Color(red: 0.35, green: 0.58, blue: 1.0)

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
    @State private var showingEndpointEditor = false

    var body: some View {
        Form {
            // --- Providers ---
            Section("Providers") {
                ForEach(appState.aiSettings.endpoints) { endpoint in
                    EndpointRow(endpoint: endpoint) {
                        editingEndpoint = endpoint
                        showingEndpointEditor = true
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
                    showingEndpointEditor = true
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

                if appState.aiSettings.transcriptionMode == .cloud {
                    Picker("Provider", selection: $appState.aiSettings.sttEndpointID) {
                        Text("None").tag(nil as UUID?)
                        ForEach(sttCapableEndpoints) { endpoint in
                            Text(endpoint.name).tag(endpoint.id as UUID?)
                        }
                    }
                    .padding(.leading, 20)
                    if sttCapableEndpoints.isEmpty {
                        Text("Add a provider with an STT model (OpenAI or Google)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.leading, 20)
                    }
                }
            }

            // --- Post-Processing ---
            Section("Post-Processing") {
                Picker(selection: $appState.aiSettings.postProcessingMode) {
                    Text("Regex only").tag(PostProcessingMode.regex)
                    Text("LLM").tag(PostProcessingMode.llm)
                    Text("Regex then LLM").tag(PostProcessingMode.regexThenLLM)
                } label: {
                    EmptyView()
                }
                .pickerStyle(.radioGroup)

                if appState.aiSettings.postProcessingMode != .regex {
                    Picker("Provider", selection: $appState.aiSettings.llmEndpointID) {
                        Text("None").tag(nil as UUID?)
                        ForEach(llmCapableEndpoints) { endpoint in
                            Text(endpoint.name).tag(endpoint.id as UUID?)
                        }
                    }
                    .padding(.leading, 20)
                    if llmCapableEndpoints.isEmpty {
                        Text("Add a provider with an LLM model")
                            .font(.caption)
                            .foregroundStyle(.secondary)
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
        .sheet(isPresented: $showingEndpointEditor) {
            if let endpoint = editingEndpoint {
                EndpointEditorView(
                    endpoint: endpoint,
                    isNew: !appState.aiSettings.endpoints.contains(where: { $0.id == endpoint.id })
                ) { saved in
                    saveEndpoint(saved)
                    showingEndpointEditor = false
                } onCancel: {
                    showingEndpointEditor = false
                }
            }
        }
    }

    private var sttCapableEndpoints: [APIEndpoint] {
        appState.aiSettings.endpoints.filter { endpoint in
            endpoint.isEnabled && endpoint.sttModel != nil &&
            (endpoint.apiProtocol == .openAI || endpoint.apiProtocol == .google)
        }
    }

    private var llmCapableEndpoints: [APIEndpoint] {
        appState.aiSettings.endpoints.filter { $0.isEnabled && $0.llmModel != nil }
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
                HStack(spacing: 8) {
                    if let stt = endpoint.sttModel {
                        Text("STT: \(stt)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let llm = endpoint.llmModel {
                        Text("LLM: \(llm)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
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
    @State private var isTesting = false
    @State private var testStatus: TestStatus?
    @State private var testMessage: String?

    enum TestStatus { case pass, fail }

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

                Section("Models") {
                    if endpoint.apiProtocol != .anthropic {
                        TextField("STT Model", text: sttModelBinding, prompt: Text("e.g. whisper-1"))
                    }
                    TextField("LLM Model", text: llmModelBinding, prompt: Text("e.g. gpt-4o-mini"))
                }

                Section("LLM System Prompt") {
                    TextEditor(text: systemPromptBinding)
                        .frame(height: 80)
                        .font(.system(size: 12, design: .monospaced))
                }
            }
            .formStyle(.grouped)

            VStack(spacing: 8) {
                HStack {
                    Button {
                        testConnection()
                    } label: {
                        HStack(spacing: 6) {
                            if isTesting {
                                ProgressView()
                                    .controlSize(.small)
                                    .transition(.opacity)
                            } else if let status = testStatus {
                                Image(systemName: status == .pass ? "checkmark.circle.fill" : "xmark.circle.fill")
                                    .foregroundStyle(status == .pass ? .green : .red)
                                    .transition(.opacity)
                            }
                            Text(isTesting ? "Testing\u{2026}" : "Test Connection")
                        }
                        .animation(.easeInOut(duration: 0.2), value: isTesting)
                        .animation(.easeInOut(duration: 0.2), value: testStatus)
                    }
                    .disabled(isTesting || apiKeyText.isEmpty)

                    Spacer()
                    Button("Cancel", action: onCancel)
                    Button(isNew ? "Add" : "Save") { save() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(endpoint.name.isEmpty)
                }

                if let msg = testMessage {
                    Text(msg)
                        .font(.system(size: 11))
                        .foregroundColor(testStatus == .pass ? .secondary : .red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .padding()
            .animation(.easeInOut(duration: 0.2), value: testMessage)
        }
        .frame(width: 460, height: 520)
    }

    private var baseURLBinding: Binding<String> {
        Binding(
            get: { endpoint.baseURL.absoluteString },
            set: { if let url = URL(string: $0) { endpoint.baseURL = url } }
        )
    }

    private var sttModelBinding: Binding<String> {
        Binding(
            get: { endpoint.sttModel ?? "" },
            set: { endpoint.sttModel = $0.isEmpty ? nil : $0 }
        )
    }

    private var llmModelBinding: Binding<String> {
        Binding(
            get: { endpoint.llmModel ?? "" },
            set: { endpoint.llmModel = $0.isEmpty ? nil : $0 }
        )
    }

    private var systemPromptBinding: Binding<String> {
        Binding(
            get: { endpoint.llmSystemPrompt ?? LLMPostProcessor.defaultSystemPrompt },
            set: { endpoint.llmSystemPrompt = $0 }
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

    private func testConnection() {
        isTesting = true
        testStatus = nil
        testMessage = nil
        Task {
            do {
                if let model = endpoint.llmModel, !model.isEmpty {
                    let client = buildLLMClient()
                    let result = try await client.complete(system: "Reply with OK", user: "test")
                    testStatus = .pass
                    testMessage = "OK \u{2014} \(result.prefix(50))"
                } else {
                    testStatus = .fail
                    testMessage = "No model configured to test"
                }
            } catch {
                testStatus = .fail
                testMessage = error.localizedDescription
            }
            isTesting = false
        }
    }

    private func buildLLMClient() -> any LLMClient {
        switch endpoint.apiProtocol {
        case .openAI:
            return OpenAILLMClient(baseURL: endpoint.baseURL, apiKey: apiKeyText, model: endpoint.llmModel ?? "gpt-4o-mini")
        case .anthropic:
            return AnthropicLLMClient(baseURL: endpoint.baseURL, apiKey: apiKeyText, model: endpoint.llmModel ?? "claude-sonnet-4-6-20250514")
        case .google:
            return GoogleLLMClient(baseURL: endpoint.baseURL, apiKey: apiKeyText, model: endpoint.llmModel ?? "gemini-2.0-flash")
        }
    }
}
