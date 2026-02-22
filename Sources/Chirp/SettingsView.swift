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
                        TextField("Model", text: sttModelBinding, prompt: Text("e.g. whisper-1"))
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
                Text("Regex applies pattern-based fixes (filler words, stutters). LLM uses AI to refine grammar and punctuation.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if appState.aiSettings.postProcessingMode != .regex {
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
                        TextField("Model", text: llmModelBinding, prompt: Text("e.g. gpt-4o-mini"))
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
