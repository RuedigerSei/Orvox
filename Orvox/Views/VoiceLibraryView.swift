import SwiftUI
import AVFoundation

struct VoiceLibraryView: View {
    @State private var store       = VoiceProfileStore.shared
    @State private var showImport  = false
    @State private var testingID: UUID? = nil
    @State private var player: AVAudioPlayer?

    private let columns = [GridItem(.adaptive(minimum: 200, maximum: 280))]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(store.profiles) { profile in
                    VoiceCard(
                        profile: profile,
                        isTesting: testingID == profile.id,
                        onTest: { testVoice(profile) },
                        onDelete: profile.isBuiltIn ? nil : { store.remove(id: profile.id) }
                    )
                }

                // Add new voice card
                AddVoiceCard { showImport = true }
            }
            .padding(20)
        }
        .navigationTitle("Voice Profiles")
        .sheet(isPresented: $showImport) {
            VoiceImportSheet { profile in
                store.add(profile: profile)
            }
        }
    }

    private func testVoice(_ profile: VoiceProfile) {
        guard testingID == nil else { return }
        testingID = profile.id

        let sentence = "The quick brown fox jumps over the lazy dog in the afternoon sunlight."
        let refPath  = store.absoluteURL(for: profile)?.path

        Task {
            do {
                let wav = try await TTSClient.shared.synthesize(
                    text: sentence,
                    referenceAudioPath: refPath,
                    preset: .audiobook
                )
                await MainActor.run {
                    player = try? AVAudioPlayer(data: wav)
                    player?.play()
                    testingID = nil
                }
            } catch {
                await MainActor.run { testingID = nil }
            }
        }
    }
}

// MARK: - VoiceCard

struct VoiceCard: View {
    let profile: VoiceProfile
    let isTesting: Bool
    let onTest: () -> Void
    let onDelete: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                ZStack {
                    Circle()
                        .fill(profile.isBuiltIn ? Color.accentColor.opacity(0.15) : Color.purple.opacity(0.15))
                        .frame(width: 36, height: 36)
                    Text(profile.isBuiltIn ? "🤖" : "🎙️")
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(profile.name)
                        .font(.system(size: 13, weight: .semibold))
                    Text(profile.isBuiltIn ? "Built-in · Neural" : durationLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if profile.isBuiltIn {
                    badgeLabel("Default", color: .green)
                } else {
                    badgeLabel("Cloned", color: .purple)
                }
            }

            WaveformView(profile: profile)
                .frame(height: 28)

            HStack {
                Button(isTesting ? "Testing…" : "Test Voice") { onTest() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(isTesting)
                    .overlay(isTesting ? AnyView(ProgressView().scaleEffect(0.6)) : AnyView(EmptyView()))

                Spacer()

                if let del = onDelete {
                    Button(role: .destructive, action: del) {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.red)
                }
            }
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(profile.isBuiltIn ? Color.clear : Color.purple.opacity(0.4), lineWidth: 1)
        )
    }

    private var durationLabel: String {
        guard let d = profile.durationSeconds else { return "Cloned" }
        return String(format: "Cloned · %.1fs sample", d)
    }

    private func badgeLabel(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 9.5, weight: .semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(color.opacity(0.12))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }
}

// MARK: - Waveform view (static visualisation from sample or placeholder bars)

struct WaveformView: View {
    let profile: VoiceProfile
    @State private var bars: [CGFloat] = []

    var body: some View {
        GeometryReader { geo in
            HStack(alignment: .center, spacing: 2) {
                ForEach(bars.indices, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(profile.isBuiltIn ? Color.accentColor : Color.purple)
                        .opacity(0.7)
                        .frame(width: 2, height: bars[i] * geo.size.height)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color.secondary.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .onAppear { bars = makeBars() }
    }

    private func makeBars() -> [CGFloat] {
        // 40 bars with a rough sine-wave envelope to look natural
        (0..<40).map { i in
            let base = 0.2 + 0.6 * abs(sin(Double(i) * 0.47 + (profile.id.hashValue % 10 == 0 ? 0 : Double(profile.id.hashValue % 6))))
            return CGFloat(base)
        }
    }
}

// MARK: - Add voice card

struct AddVoiceCard: View {
    let onTap: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 8) {
                Text("+")
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(.secondary)
                Text("New Voice Profile")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Drop MP3 / M4A sample here")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 30)
            .background(hovered ? Color.accentColor.opacity(0.06) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.secondary.opacity(0.3), style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
            )
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}
