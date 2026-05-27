import SwiftUI

struct SettingsView: View {
    @AppStorage("serverURL")               private var serverURL               = "http://127.0.0.1:11435"
    @AppStorage("modelSize")               private var modelSizeRaw            = ModelSize.quality.rawValue
    @AppStorage("concurrentChunks")        private var concurrentChunks        = 2
    @AppStorage("defaultPreset")           private var defaultPresetRaw        = AudioPreset.audiobook.rawValue
    @AppStorage("outputFolder")            private var outputFolder            = ""
    @AppStorage("defaultVoiceProfileID")   private var defaultVoiceProfileID   = ""
    @AppStorage("defaultNarrationStyle")   private var defaultNarrationStyle   = ""

    @State private var voiceStore = VoiceProfileStore.shared
    @State private var serverStatus: ServerStatus = .unknown
    @State private var serverLabel: String? = nil
    @State private var isCheckingServer = false

    private var modelSize: ModelSize {
        ModelSize(rawValue: modelSizeRaw) ?? .quality
    }
    private var defaultPreset: AudioPreset {
        AudioPreset(rawValue: defaultPresetRaw) ?? .audiobook
    }

    var body: some View {
        Form {
            // ── Server ──────────────────────────────────────────
            Section("TTS Server") {
                HStack {
                    TextField("Server URL", text: $serverURL)
                        .textFieldStyle(.roundedBorder)
                    serverIndicator
                    if let label = serverLabel {
                        Text(label)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Button("Check") { checkServer() }
                        .disabled(isCheckingServer)
                }

                Picker("Model", selection: $modelSizeRaw) {
                    ForEach(ModelSize.allCases, id: \.rawValue) { size in
                        Text(size.displayName).tag(size.rawValue)
                    }
                }
                .onChange(of: modelSizeRaw) { _, new in
                    applyModelChange(ModelSize(rawValue: new) ?? .quality)
                }
            }

            // ── Output ──────────────────────────────────────────
            Section("Output") {
                Picker("Default preset", selection: $defaultPresetRaw) {
                    ForEach(AudioPreset.allCases) { p in
                        Text(p.displayName).tag(p.rawValue)
                    }
                }

                Picker("Default style", selection: $defaultNarrationStyle) {
                    Text("None").tag("")
                    Divider()
                    ForEach(NarrationStyle.allCases) { s in
                        Text(s.displayName).tag(s.rawValue)
                    }
                }

                Picker("Default voice", selection: $defaultVoiceProfileID) {
                    Text("Bundled Clone").tag("")
                    if !voiceStore.profiles.isEmpty { Divider() }
                    ForEach(voiceStore.profiles) { p in
                        Text(p.name).tag(p.id.uuidString)
                    }
                }

                HStack {
                    TextField("Output folder", text: $outputFolder)
                        .textFieldStyle(.roundedBorder)
                        .truncationMode(.head)
                    Button("Choose…") { chooseOutputFolder() }
                }
                if outputFolder.isEmpty {
                    Text("Default: ~/Documents/Orvox/")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // ── Narration Prompts ────────────────────────────────
            Section("Narration Prompts") {
                Text("These prompts guide the TTS model's speaking style. Edits are saved automatically and persist across launches.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ForEach(NarrationStyle.allCases) { style in
                    NarrationPromptRow(style: style)
                }
            }

            // ── Performance ──────────────────────────────────────
            Section("Performance") {
                Stepper("Concurrent chunks: \(concurrentChunks)",
                        value: $concurrentChunks, in: 1...8)
                Text("MLX uses a single worker; the GPU handles parallelism internally.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        .onAppear { checkServer() }
    }

    // MARK: - Server status

    private var serverIndicator: some View {
        Group {
            switch serverStatus {
            case .unknown:  Circle().fill(.gray)
            case .ok:       Circle().fill(.green)
            case .error:    Circle().fill(.red)
            }
        }
        .frame(width: 10, height: 10)
    }

    private func checkServer() {
        isCheckingServer = true
        Task {
            let info = await TTSClient.shared.healthInfo()
            await MainActor.run {
                serverStatus = info.ok ? .ok : .error
                if info.ok {
                    let deviceLabel = info.device ?? "unknown"
                    serverLabel = "MLX · \(deviceLabel)"
                } else {
                    serverLabel = nil
                }
                isCheckingServer = false
            }
        }
    }

    private func applyModelChange(_ size: ModelSize) {
        Task { try? await TTSClient.shared.configure(modelSize: size) }
    }

    private func chooseOutputFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories  = true
        panel.canChooseFiles        = false
        panel.canCreateDirectories  = true
        panel.prompt = "Choose Folder"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        outputFolder = url.path
    }

    enum ServerStatus { case unknown, ok, error }
}

// MARK: - Narration prompt row

private struct NarrationPromptRow: View {
    let style: NarrationStyle

    @State private var text: String = ""
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: 12)
                        Text(style.displayName)
                            .font(.system(size: 13, weight: .medium))
                        if style.isCustomised {
                            Text("edited")
                                .font(.system(size: 10, weight: .semibold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.accentColor.opacity(0.12))
                                .foregroundStyle(Color.accentColor)
                                .clipShape(Capsule())
                        }
                    }
                }
                .buttonStyle(.plain)

                Spacer()

                if style.isCustomised {
                    Button("Reset") {
                        style.resetToDefault()
                        text = style.defaultInstruct
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }

            if isExpanded {
                TextEditor(text: $text)
                    .font(.system(size: 12))
                    .frame(minHeight: 72)
                    .padding(6)
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
                    )
                    .onChange(of: text) { _, newValue in
                        style.saveCustomInstruct(newValue)
                    }
            }
        }
        .padding(.vertical, 2)
        .onAppear { text = style.resolvedInstruct }
    }
}
