import Foundation

actor PipelineCoordinator {
    static let shared = PipelineCoordinator()

    private var activeTasks: [UUID: Task<Void, Error>] = [:]
    private var crashedJobID: UUID? = nil   // set by health watchdog before cancelling

    private init() {}

    // MARK: - Public API

    func convert(jobID: UUID, voiceProfileURL: URL?) async throws {
        let task = Task<Void, Error> {
            try await self.runPipeline(jobID: jobID, voiceProfileURL: voiceProfileURL)
        }
        activeTasks[jobID] = task
        defer { activeTasks.removeValue(forKey: jobID) }
        try await task.value
    }

    func cancel(jobID: UUID) {
        activeTasks[jobID]?.cancel()
        activeTasks.removeValue(forKey: jobID)
    }

    var isActive: Bool { !activeTasks.isEmpty }

    // MARK: - Pipeline

    private func runPipeline(jobID: UUID, voiceProfileURL: URL?) async throws {
        guard let job = await fetchJob(jobID) else { return }

        await setStatus(jobID, .converting, progress: 0)

        // ── 1. Extract text ───────────────────────────────────
        let doc: ExtractedDocument
        do {
            doc = try await TextExtractor.extract(from: job.inputURL)
        } catch {
            await setStatus(jobID, .failed, errorMessage: error.localizedDescription)
            return
        }

        if let pages = doc.pageCount {
            await MainActor.run { JobStore.shared.updatePageCount(id: jobID, pageCount: pages) }
        }

        // ── 2. Chunk ──────────────────────────────────────────
        let chunks = ChunkSplitter.split(text: doc.text)
        guard !chunks.isEmpty else {
            await setStatus(jobID, .failed, errorMessage: "No text found in file")
            return
        }

        // ── 3. TTS in parallel ────────────────────────────────
        let concurrency = max(1, min(8, UserDefaults.standard.integer(forKey: "concurrentChunks") > 0
            ? UserDefaults.standard.integer(forKey: "concurrentChunks") : 3))
        let preset = job.preset
        let total  = chunks.count

        // Built-in speaker: used only when the job has no custom voice profile.
        let builtInSpeaker: String? = {
            guard voiceProfileURL == nil else { return nil }
            let name = UserDefaults.standard.string(forKey: "defaultBuiltInVoiceName") ?? ""
            return name.isEmpty ? nil : name
        }()

        await MainActor.run { JobStore.shared.markStarted(id: jobID, chunksTotal: total) }

        var results: [(index: Int, wav: Data)] = []
        results.reserveCapacity(total)

        // Health watchdog: poll every 20 s; cancel the job after 3 consecutive misses
        // so we don't wait out the full 900 s URLSession timeout when the server hangs.
        let watchdog = Task {
            var failures = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(20))
                guard !Task.isCancelled else { break }
                if await TTSClient.shared.health() {
                    failures = 0
                } else {
                    failures += 1
                    print("[watchdog] server health check failed (\(failures)/3)")
                    if failures >= 3 {
                        print("[watchdog] server unreachable — cancelling job \(jobID)")
                        self.crashedJobID = jobID
                        self.cancel(jobID: jobID)
                        break
                    }
                }
            }
        }
        defer { watchdog.cancel() }

        do {
            try await withThrowingTaskGroup(of: (Int, Data).self) { group in
                var inFlight = 0

                for chunk in chunks {
                    try Task.checkCancellation()

                    if inFlight >= concurrency {
                        let (idx, wav) = try await group.next()!
                        results.append((idx, wav))
                        inFlight -= 1
                        let done = results.count
                        await MainActor.run { JobStore.shared.updateChunks(id: jobID, completed: done, total: total) }
                        await setProgress(jobID, Double(done) / Double(total) * 0.85)
                    }

                    let chunkIndex = chunk.index
                    let text       = chunk.text
                    let refPath    = voiceProfileURL?.path
                    let speaker    = builtInSpeaker
                    let wordCount  = text.split(separator: " ").count

                    group.addTask {
                        let t0 = Date()
                        print("[tts] chunk \(chunkIndex)/\(total) start (\(wordCount) words)")
                        do {
                            let wav = try await TTSClient.shared.synthesize(
                                text: text,
                                speaker: speaker,
                                referenceAudioPath: refPath,
                                preset: preset
                            )
                            let elapsed = Date().timeIntervalSince(t0)
                            print(String(format: "[tts] chunk %d done in %.1fs (%d bytes)", chunkIndex, elapsed, wav.count))
                            return (chunkIndex, wav)
                        } catch {
                            let elapsed = Date().timeIntervalSince(t0)
                            print(String(format: "[tts] chunk %d FAILED after %.1fs — %@", chunkIndex, elapsed, String(describing: error)))
                            throw error
                        }
                    }
                    inFlight += 1
                }

                for try await pair in group {
                    results.append(pair)
                    let done = results.count
                    await MainActor.run { JobStore.shared.updateChunks(id: jobID, completed: done, total: total) }
                    await setProgress(jobID, Double(done) / Double(total) * 0.85)
                }
            }
        } catch is CancellationError {
            let serverDied = crashedJobID == jobID
            crashedJobID = nil
            let msg = serverDied ? "TTS server stopped responding — job cancelled" : "Cancelled"
            await setStatus(jobID, .failed, errorMessage: msg)
            return
        } catch let urlErr as URLError {
            let msg: String
            switch urlErr.code {
            case .timedOut:              msg = "Request timed out — synthesis took too long"
            case .networkConnectionLost: msg = "Connection lost — TTS server may have crashed"
            case .cannotConnectToHost:   msg = "Cannot reach TTS server"
            default:                     msg = urlErr.localizedDescription
            }
            print("[pipeline] URLError: code=\(urlErr.code.rawValue) \(urlErr.localizedDescription)")
            await setStatus(jobID, .failed, errorMessage: msg)
            return
        } catch {
            print("[pipeline] error: \(type(of: error)) \(error)")
            await setStatus(jobID, .failed, errorMessage: error.localizedDescription)
            return
        }

        // ── 4. Order WAV chunks ───────────────────────────────
        results.sort { $0.index < $1.index }
        let orderedWAVs = results.map { $0.wav }

        // ── 5. Build chapter markers ──────────────────────────
        // Accumulate the duration of each chunk so we know the wall-clock
        // start time of every chunk in the final concatenated audio.
        var chunkStartTimes: [Double] = []
        var runningTime: Double = 0
        for wav in orderedWAVs {
            chunkStartTimes.append(runningTime)
            runningTime += M4AWriter.duration(of: wav)
        }

        let chapterMarkers: [ChapterMarker] = chunks.compactMap { chunk in
            guard let title = chunk.chapterTitle else { return nil }
            let ts = chunk.index < chunkStartTimes.count ? chunkStartTimes[chunk.index] : 0
            return ChapterMarker(title: title, timestamp: ts, chunkIndex: chunk.index)
        }

        // ── 6. Encode to M4A ──────────────────────────────────
        await setProgress(jobID, 0.90)

        let outputURL: URL
        do {
            outputURL = try outputFileURL(for: job.inputURL, preset: preset)
            let title = job.inputURL.deletingPathExtension().lastPathComponent
            try await M4AWriter.assemble(
                wavChunks: orderedWAVs,
                preset: preset,
                outputURL: outputURL,
                title: title,
                author: "",
                chapterMarkers: chapterMarkers
            )
        } catch {
            await setStatus(jobID, .failed, errorMessage: error.localizedDescription)
            return
        }

        await setStatus(jobID, .done, progress: 1.0, outputURL: outputURL)
    }

    // MARK: - Helpers

    private func fetchJob(_ id: UUID) async -> Job? {
        await MainActor.run { JobStore.shared.jobs.first { $0.id == id } }
    }

    private func setStatus(_ id: UUID, _ status: JobStatus,
                            progress: Double? = nil,
                            outputURL: URL? = nil,
                            errorMessage: String? = nil) async {
        await MainActor.run {
            JobStore.shared.updateStatus(id: id, status: status, progress: progress,
                                          outputURL: outputURL, errorMessage: errorMessage)
        }
    }

    private func setProgress(_ id: UUID, _ progress: Double) async {
        await MainActor.run { JobStore.shared.updateProgress(id: id, progress: progress) }
    }

    private func outputFileURL(for inputURL: URL, preset: AudioPreset) throws -> URL {
        let folder: URL
        let saved = UserDefaults.standard.string(forKey: "outputFolder") ?? ""
        if !saved.isEmpty {
            folder = URL(fileURLWithPath: saved)
        } else {
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            folder = docs.appendingPathComponent("Orvox")
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let ext = preset == .audiobook ? "m4b" : "m4a"
        let name = inputURL.deletingPathExtension().lastPathComponent + "." + ext
        return folder.appendingPathComponent(name)
    }
}
