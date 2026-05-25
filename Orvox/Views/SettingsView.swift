import SwiftUI

struct SettingsView: View {
    @AppStorage("serverURL")        private var serverURL        = "http://localhost:11435"
    @AppStorage("modelSize")        private var modelSizeRaw     = ModelSize.quality.rawValue
    @AppStorage("concurrentChunks") private var concurrentChunks = 3
    @AppStorage("defaultPreset")    private var defaultPresetRaw = AudioPreset.audiobook.rawValue
    @AppStorage("outputFolder")     private var outputFolder     = ""

    @State private var serverStatus: ServerStatus = .unknown
    @State private var inferenceDevice: String? = nil
    @State private var isCheckingServer = false

    private var modelSize: ModelSize {
        get { ModelSize(rawValue: modelSizeRaw) ?? .quality }
    }
    private var defaultPreset: AudioPreset {
        get { AudioPreset(rawValue: defaultPresetRaw) ?? .audiobook }
    }

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
