import Foundation

final class PythonServerManager: @unchecked Sendable {
    static let shared = PythonServerManager()

    private var process: Process?
    private(set) var isRunning = false
    private let port = 11435
    private var launchTime: Date?

    private init() {}

    func start() async {
        guard process == nil else { return }

        // If something healthy is already on this port, adopt it.
        if await checkHealth() {
            print("[PythonServerManager] adopted existing server on port \(port)")
            return
        }

        // No healthy server found — evict anything that might still be holding the port
        // (crashed server, previous run that didn't clean up, etc.).
        killOrphanedServer()
        // Brief pause for the OS to release the port after SIGKILL.
        try? await Task.sleep(nanoseconds: 500_000_000)

        guard let scriptURL = serverScriptURL() else {
            print("[PythonServerManager] tts_server/server.py not found in bundle")
            return
        }

        let pythonURL = pythonExecutableURL()
        let proc = Process()
        proc.executableURL = pythonURL
        proc.arguments = [scriptURL.path]
        proc.environment = buildEnv(serverDir: scriptURL.deletingLastPathComponent())

        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError  = pipe

        pipe.fileHandleForReading.readabilityHandler = { handle in
            if let line = String(data: handle.availableData, encoding: .utf8), !line.isEmpty {
                print("[TTS]", line.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }

        proc.terminationHandler = { [weak self] _ in
            guard let self else { return }
            let code = proc.terminationStatus
            print("[PythonServerManager] server exited (code \(code))")
            // Don't restart if stop() was called (process already nil) or if the
            // server died on startup (uptime < 10 s = bind error, missing dep, etc.).
            guard self.process != nil else { return }
            let uptime = self.launchTime.map { Date().timeIntervalSince($0) } ?? 0
            guard uptime > 10 else {
                print("[PythonServerManager] server died on startup (uptime \(Int(uptime))s) — not restarting")
                self.process = nil
                self.isRunning = false
                return
            }
            self.process = nil
            self.isRunning = false
            Task { await self.start() }
        }

        do {
            try proc.run()
            launchTime = Date()
            process = proc
        } catch {
            print("[PythonServerManager] launch failed: \(error)")
            return
        }

        Task { await self.waitForHealth() }
    }

    func stop() {
        // Kill the managed process and any orphaned server still holding the port
        // (e.g. a previously adopted server that we didn't launch ourselves).
        let p = process
        process = nil
        isRunning = false
        p?.terminate()
        killOrphanedServer()
    }

    func restart() async {
        stop()
        await start()
    }

    func checkHealth() async -> Bool {
        guard let url = URL(string: "http://127.0.0.1:\(port)/health") else { return false }
        do {
            let (_, resp) = try await URLSession.shared.data(from: url)
            let ok = (resp as? HTTPURLResponse)?.statusCode == 200
            isRunning = ok
            return ok
        } catch {
            isRunning = false
            return false
        }
    }

    // MARK: - Private

    private func killOrphanedServer() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "lsof -ti:\(port) | xargs kill -9 2>/dev/null; true"]
        task.standardOutput = FileHandle.nullDevice
        task.standardError  = FileHandle.nullDevice
        try? task.run()
    }

    private func serverScriptURL() -> URL? {
        // Prefer venv-adjacent server if present
        if let bundleRes = Bundle.main.url(forResource: "tts_server", withExtension: nil) {
            let script = bundleRes.appendingPathComponent("server.py")
            if FileManager.default.fileExists(atPath: script.path) { return script }
        }
        // Fall back to resource folder named tts_server directly in bundle
        if let script = Bundle.main.url(forResource: "server", withExtension: "py") {
            return script
        }
        return nil
    }

    private func pythonExecutableURL() -> URL {
        // 1. Explicit override via scheme env var (used during development).
        if let envPath = ProcessInfo.processInfo.environment["TTS_VENV_PATH"], !envPath.isEmpty {
            let py = URL(fileURLWithPath: envPath).appendingPathComponent("bin/python3")
            if FileManager.default.fileExists(atPath: py.path) { return py }
        }
        // 2. Venv shipped next to the .app (production layout).
        let appDir = Bundle.main.bundleURL.deletingLastPathComponent()
        let bundled = appDir.appendingPathComponent("tts_venv/bin/python3")
        if FileManager.default.fileExists(atPath: bundled.path) { return bundled }
        // 3. Last resort.
        return URL(fileURLWithPath: "/usr/bin/python3")
    }

    private func buildEnv(serverDir: URL) -> [String: String] {
        var env = ProcessInfo.processInfo.environment

        // Prepend Homebrew paths so sox and other CLI tools are visible.
        let brewPaths = ["/opt/homebrew/bin", "/usr/local/bin"]
        let existingPATH = env["PATH"] ?? "/usr/bin:/bin"
        let extraPATH = brewPaths.filter { !existingPATH.contains($0) }.joined(separator: ":")
        env["PATH"] = extraPATH.isEmpty ? existingPATH : "\(extraPATH):\(existingPATH)"

        let existing = env["PYTHONPATH"] ?? ""
        env["PYTHONPATH"] = existing.isEmpty ? serverDir.path : "\(serverDir.path):\(existing)"
        env["TTS_PORT"] = "\(port)"
        return env
    }

    private func waitForHealth() async {
        // First-run model download can take several minutes; allow up to 15 minutes.
        let maxAttempts = 900
        for attempt in 1...maxAttempts {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if await checkHealth() {
                print("[PythonServerManager] server ready after \(attempt)s")
                return
            }
        }
        print("[PythonServerManager] server did not become healthy after \(maxAttempts)s")
    }
}
