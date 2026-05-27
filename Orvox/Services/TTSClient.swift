import Foundation

private struct SynthesizeBody: Encodable {
    let text: String
    let reference_audio_path: String?
    let preset: String
    let instruct: String?
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

    func synthesize(text: String, referenceAudioPath: String?, preset: AudioPreset, instruct: String?) async throws -> Data {
        let base = serverBaseURL()
        guard let url = URL(string: "\(base)/synthesize") else { throw TTSError.invalidURL }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(
            SynthesizeBody(text: text, reference_audio_path: referenceAudioPath, preset: preset.rawValue, instruct: instruct)
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
        let backend: String?
    }

    func health() async -> Bool {
        await healthInfo().ok
    }

    func healthInfo() async -> HealthInfo {
        let base = serverBaseURL()
        guard let url = URL(string: "\(base)/health") else {
            return HealthInfo(ok: false, device: nil, backend: nil)
        }
        do {
            let (data, resp) = try await session.data(from: url)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
                return HealthInfo(ok: false, device: nil, backend: nil)
            }
            let json    = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            let device  = json?["device"]  as? String
            let backend = json?["backend"] as? String
            return HealthInfo(ok: true, device: device, backend: backend)
        } catch {
            return HealthInfo(ok: false, device: nil, backend: nil)
        }
    }

    private func serverBaseURL() -> String {
        let stored = UserDefaults.standard.string(forKey: "serverURL") ?? "http://127.0.0.1:11435"
        // Normalize legacy "localhost" to the explicit IPv4 address so URLSession
        // doesn't try ::1 first, hit ECONNREFUSED, and cancel the first request.
        return stored.replacingOccurrences(of: "://localhost", with: "://127.0.0.1")
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
