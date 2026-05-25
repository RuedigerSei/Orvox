import SwiftUI
import UniformTypeIdentifiers
import AVFoundation

struct VoiceImportSheet: View {
    let onSave: (VoiceProfile) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var selectedURL: URL? = nil
    @State private var duration: Double? = nil
    @State private var isDragOver = false
    @State private var isSaving   = false
    @State private var errorMsg: String? = nil

    private let store = VoiceProfileStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("New Voice Profile")
                .font(.headline)

            TextField("Profile name", text: $name)
                .textFieldStyle(.roundedBorder)

            // Drop zone
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(
                        isDragOver ? Color.accentColor : Color.secondary.opacity(0.35),
                        style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])
                    )
                    .background(RoundedRectangle(cornerRadius: 10)
                        .fill(isDragOver ? Color.accentColor.opacity(0.06) : Color.clear))

                if let url = selectedURL {
                    VStack(spacing: 6) {
                        Image(systemName: "waveform")
                            .font(.system(size: 28))
                            .foregroundStyle(Color.accentColor)
                        Text(url.lastPathComponent)
                            .font(.system(size: 12, weight: .medium))
                        if let d = duration {
                            Text(String(format: "%.1f seconds", d))
                                .font(.caption)
                                .foregroundStyle(d < 3 || d > 15 ? .red : .secondary)
                            if d < 3 || d > 15 {
                                Text("Target: 3–15 seconds for best cloning quality")
                                    .font(.caption)
                                    .foregroundStyle(.red)
                            }
                        }
                    }
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "mic.badge.plus")
                            .font(.system(size: 32))
                            .foregroundStyle(.secondary)
                        Text("Drop MP3 or M4A here")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                        Text("3–15 seconds of clear speech")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                        Button("Browse…") { openPanel() }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                }
            }
            .frame(height: 160)
            .onDrop(of: [.fileURL], isTargeted: $isDragOver) { providers in
                handleDrop(providers: providers)
                return true
            }

            if let err = errorMsg {
                Text(err).foregroundStyle(.red).font(.caption)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.escape)
                Button("Save") { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(name.isEmpty || selectedURL == nil || isSaving)
            }
        }
        .padding(24)
        .frame(width: 400)
    }

    private func openPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.mp3, .mpeg4Audio]
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        loadAudio(url: url)
    }

    private func handleDrop(providers: [NSItemProvider]) {
        for provider in providers {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                guard let data = item as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                DispatchQueue.main.async { self.loadAudio(url: url) }
            }
        }
    }

    private func loadAudio(url: URL) {
        selectedURL = url
        if name.isEmpty { name = url.deletingPathExtension().lastPathComponent }
        Task {
            let asset = AVURLAsset(url: url)
            let d = try? await asset.load(.duration)
            await MainActor.run {
                duration = d.map { CMTimeGetSeconds($0) }
            }
        }
    }

    private func save() {
        guard let url = selectedURL else { return }
        isSaving = true
        errorMsg = nil

        Task {
            do {
                let profile = try await store.importAudio(from: url, name: name)
                await MainActor.run {
                    onSave(profile)
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    errorMsg = error.localizedDescription
                    isSaving = false
                }
            }
        }
    }
}
