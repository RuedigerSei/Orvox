import Foundation

private struct SynthesizeBody: Encodable {
    let text: String
    let reference_audio_path: String?
    let preset: String
}

private struct ConfigBody: Encodable {
    let model_size: String
}

actor TTSClient {
    static let shared = TTSClient()

    private let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        // CPU inference can take several minutes per chunk.
        cfg.timeoutIntervalForRequest  = 900   // 15 min per chunk
        cfg.timeoutIntervalForResource = 7200  // 2 h total per request
        return URLSession(configuration: cfg)
    }()

    private init() {}

    func synthesize(text: String, referenceAudioPath: String?, preset: AudioPreset) async throws -> Data {
        let base = serverBaseURL()
        guard let url = URL(string: "\(base)/synthesize") else { throw TTSError.invalidURL }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(
            SynthesizeBody(text: text, reference_audio_path: referenceAudioPath, preset: preset.rawValue)
        )

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw TTSError.serverError(String(data: data, encoding: .utf8) ?? "unknown error")
        }
        return data
    }

    func configure(modelSize: ModelSize) async throws {
        let base = serverBaseURL()
        guard let url = URL(string: "\(base)/config") else { throw TTSError.invalidURL }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(ConfigBody(model_size: modelSize.rawValue))

        let (_, _) = try await session.data(for: req)
    }

    struct HealthInfo: Sendable {
        let ok: Bool
        let device: String?
    }

    func health() async -> Bool {
        await healthInfo().ok
    }

    func healthInfo() async -> HealthInfo {
        let base = serverBaseURL()
        guard let url = URL(string: "\(base)/health") else { return HealthInfo(ok: false, device: nil) }
        do {
            let (data, resp) = try await session.data(from: url)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
                return HealthInfo(ok: false, device: nil)
            }
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            let device = json?["device"] as? String
            return HealthInfo(ok: true, device: device)
        } catch {
            return HealthInfo(ok: false, device: nil)
        }
    }

    private func serverBaseURL() -> String {
        UserDefaults.standard.string(forKey: "serverURL") ?? "http://localhost:11435"
    }
}

enum TTSError: LocalizedError, Sendable {
    case invalidURL
    case serverError(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:          "Invalid TTS server URL"
        case .serverError(let m): "TTS error: \(m)"
        }
    }
}
