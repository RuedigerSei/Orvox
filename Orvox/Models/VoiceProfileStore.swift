import Foundation
import AVFoundation
import Observation

@MainActor
@Observable
final class VoiceProfileStore {
    static let shared = VoiceProfileStore()

    var profiles: [VoiceProfile] = [.builtIn]

    private let voicesDir: URL

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        voicesDir = appSupport.appendingPathComponent("Orvox/Voices")
        try? FileManager.default.createDirectory(at: voicesDir, withIntermediateDirectories: true)
        load()
    }

    func add(profile: VoiceProfile) {
        profiles.append(profile)
        persist()
    }

    func remove(id: UUID) {
        guard let profile = profiles.first(where: { $0.id == id }) else { return }
        if let filename = profile.sampleAudioFilename {
            try? FileManager.default.removeItem(at: voicesDir.appendingPathComponent(filename))
        }
        profiles.removeAll { $0.id == id }
        persist()
    }

    func absoluteURL(for profile: VoiceProfile) -> URL? {
        guard let filename = profile.sampleAudioFilename else { return nil }
        return voicesDir.appendingPathComponent(filename)
    }

    /// Copies the audio file into the Voices dir and returns a profile with the stored filename.
    func importAudio(from sourceURL: URL, name: String) async throws -> VoiceProfile {
        let ext = sourceURL.pathExtension
        let filename = UUID().uuidString + "." + ext
        let dest = voicesDir.appendingPathComponent(filename)
        try FileManager.default.copyItem(at: sourceURL, to: dest)

        let duration = try await audioDuration(url: dest)
        let profile = VoiceProfile(name: name, sampleAudioFilename: filename, durationSeconds: duration)
        return profile
    }

    private func audioDuration(url: URL) async throws -> Double {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        return CMTimeGetSeconds(duration)
    }

    private func persist() {
        let custom = profiles.filter { !$0.isBuiltIn }
        guard let data = try? JSONEncoder().encode(custom) else { return }
        UserDefaults.standard.set(data, forKey: "voice_profiles_v1")
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: "voice_profiles_v1"),
              let decoded = try? JSONDecoder().decode([VoiceProfile].self, from: data) else { return }
        profiles = [.builtIn] + decoded
    }
}
