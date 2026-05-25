import SwiftUI

struct SettingsView: View {
    @AppStorage("serverURL")             private var serverURL             = "http://localhost:11435"
    @AppStorage("modelSize")             private var modelSizeRaw          = ModelSize.quality.rawValue
    @AppStorage("concurrentChunks")      private var concurrentChunks      = 3
    @AppStorage("defaultPreset")         private var defaultPresetRaw      = AudioPreset.audiobook.rawValue
    @AppStorage("outputFolder")          private var outputFolder          = ""
    @AppStorage("defaultBuiltInVoiceName") private var defaultBuiltInVoiceName = ""

    @State private var serverStatus: ServerStatus = .unknown
    @State private var inferenceDevice: String? = nil
    @State private var isCheckingServer = false

    private var modelSize: ModelSize {
        ModelSize(rawValue: modelSizeRaw) ?? .quality
    }
    private var defaultPreset: AudioPreset {
        AudioPreset(rawValue: defaultPresetRaw) ?? .audiobook
    }
    private var selectedBuiltInVoice: BuiltInVoice? {
        BuiltInVoice(rawValue: defaultBuiltInVoiceName)
    }

    private let voiceGridColumns = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]

    var body: some View {
        Form {
            // ── Server ──────────────────────────────────────────
            Section("TTS Server") {
                HStack {
                    TextField("Server URL", text: $serverURL)
                        .textFieldStyle(.roundedBorder)
                    serverIndicator
                    if let device = inferenceDevice {
                        Text(device)
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

            // ── Default Voice ────────────────────────────────────
            Section("Default Voice") {
                Text("Used when a job has no custom voice profile. All voices are cross-lingual.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                LazyVGrid(columns: voiceGridColumns, spacing: 8) {
                    BuiltInVoiceCard(
                        name: "Bundled Clone",
                        description: "Built-in reference recording",
                        language: "—",
                        isSelected: selectedBuiltInVoice == nil
                    ) { defaultBuiltInVoiceName = "" }

                    ForEach(BuiltInVoice.allCases) { voice in
                        BuiltInVoiceCard(
                            name: voice.displayName,
                            description: voice.voiceDescription,
                            language: voice.nativeLanguage,
                            isSelected: selectedBuiltInVoice == voice
                        ) { defaultBuiltInVoiceName = voice.rawValue }
                    }
                }
                .padding(.vertical, 4)
            }

            // ── Concurrency ──────────────────────────────────────
            Section("Performance") {
                Stepper("Concurrent chunks: \(concurrentChunks)",
                        value: $concurrentChunks, in: 1...8)
                Text("Higher values may improve speed on M-series Macs but increase memory pressure.")
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
                serverStatus     = info.ok ? .ok : .error
                inferenceDevice  = info.device
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

// MARK: - Voice card

private struct BuiltInVoiceCard: View {
    let name: String
    let description: String
    let language: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 3) {
                Text(name)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(isSelected ? .white : .primary)
                    .lineLimit(1)
                Text(description)
                    .font(.system(size: 10))
                    .foregroundStyle(isSelected ? .white.opacity(0.85) : .secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Text(language)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(isSelected ? Color.white.opacity(0.7) : Color.secondary.opacity(0.6))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(isSelected ? Color.accentColor : Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(isSelected ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}
