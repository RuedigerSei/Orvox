import Foundation
import AVFoundation
import CoreMedia

enum AudioWriterError: LocalizedError, Sendable {
    case noChunks
    case tempFileWrite(String)
    case readerSetup(String)
    case writerSetup(String)
    case encodingFailed(String)

    var errorDescription: String? {
        switch self {
        case .noChunks:              "No audio chunks to write"
        case .tempFileWrite(let m):  "Temp file error: \(m)"
        case .readerSetup(let m):    "Reader setup: \(m)"
        case .writerSetup(let m):    "Writer setup: \(m)"
        case .encodingFailed(let m): "Encoding failed: \(m)"
        }
    }
}

struct M4AWriter {

    /// Assembles ordered WAV chunks into a single HE-AAC M4A file.
    static func assemble(
        wavChunks: [Data],
        preset: AudioPreset,
        outputURL: URL,
        title: String,
        author: String,
        chapterMarkers: [ChapterMarker]
    ) async throws {
        guard !wavChunks.isEmpty else { throw AudioWriterError.noChunks }

        // ── Step 1: concatenate all WAV chunks into one temp WAV ──
        let tempWAV = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: tempWAV) }

        try concatenateWAV(chunks: wavChunks, to: tempWAV)

        // ── Step 2: transcode WAV → HE-AAC M4A ───────────────────
        try? FileManager.default.removeItem(at: outputURL)
        try await transcodeToM4A(
            inputURL: tempWAV,
            outputURL: outputURL,
            preset: preset,
            title: title,
            author: author
        )

        // ── Step 3: sidecar CSV with chapter timestamps ───────────
        if !chapterMarkers.isEmpty {
            try writeChapterCSV(markers: chapterMarkers, near: outputURL)
        }
    }

    // MARK: - Private

    private static func concatenateWAV(chunks: [Data], to outputURL: URL) throws {
        guard let first = chunks.first, first.count > 44 else {
            throw AudioWriterError.tempFileWrite("First chunk too small")
        }
        let format = parseWAVHeader(first)

        // Extract PCM from every chunk and merge
        var allPCM = Data()
        for chunk in chunks {
            allPCM.append(extractPCM(from: chunk))
        }

        var header = makeWAVHeader(
            sampleRate: format.sampleRate,
            channels: format.channels,
            bitsPerSample: format.bitsPerSample,
            dataSize: allPCM.count
        )
        header.append(allPCM)
        try header.write(to: outputURL)
    }

    private static func transcodeToM4A(
        inputURL: URL,
        outputURL: URL,
        preset: AudioPreset,
        title: String,
        author: String
    ) async throws {
        // All non-Sendable AVFoundation objects are created and consumed inside
        // a single detached Task. Only Sendable types cross the closure boundary.
        let sampleRate = preset.sampleRate
        let channels   = Int(preset.channelCount)
        let bitrate    = preset.bitrate

        try await Task.detached(priority: .userInitiated) {
            let asset = AVURLAsset(url: inputURL)
            let tracks = try await asset.loadTracks(withMediaType: .audio)
            guard let track = tracks.first else {
                throw AudioWriterError.readerSetup("No audio track in WAV")
            }

            let reader = try AVAssetReader(asset: asset)
            let readerOut = AVAssetReaderTrackOutput(track: track, outputSettings: [
                AVFormatIDKey:               kAudioFormatLinearPCM,
                AVLinearPCMBitDepthKey:      32,
                AVLinearPCMIsFloatKey:       true,
                AVLinearPCMIsNonInterleaved: false,
            ])
            readerOut.alwaysCopiesSampleData = false
            guard reader.canAdd(readerOut) else {
                throw AudioWriterError.readerSetup("Cannot add reader output")
            }
            reader.add(readerOut)

            let writer = try AVAssetWriter(outputURL: outputURL, fileType: .m4a)
            let writerIn = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey:            kAudioFormatMPEG4AAC_HE,
                AVSampleRateKey:          sampleRate,
                AVNumberOfChannelsKey:    channels,
                AVEncoderBitRateKey:      bitrate,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
            ])
            writerIn.expectsMediaDataInRealTime = false
            guard writer.canAdd(writerIn) else {
                throw AudioWriterError.writerSetup("Cannot add writer input")
            }
            writer.add(writerIn)

            func meta(_ key: AVMetadataKey, _ value: String) -> AVMetadataItem {
                let i = AVMutableMetadataItem()
                i.keySpace = .common
                i.key      = key as NSString
                i.value    = value as NSString
                return i
            }
            writer.metadata = [
                meta(.commonKeyTitle,  title),
                meta(.commonKeyArtist, author),
            ]

            reader.startReading()
            writer.startWriting()
            writer.startSession(atSourceTime: .zero)

            drainLoop: while reader.status == .reading || writerIn.isReadyForMoreMediaData {
                guard writerIn.isReadyForMoreMediaData else { continue }
                if let buf = readerOut.copyNextSampleBuffer() {
                    writerIn.append(buf)
                } else {
                    writerIn.markAsFinished()
                    break drainLoop
                }
            }

            await writer.finishWriting()

            if let err = writer.error {
                throw err
            } else if reader.status == .failed, let err = reader.error {
                throw err
            }
        }.value
    }

    private static func writeChapterCSV(markers: [ChapterMarker], near outputURL: URL) throws {
        let csvURL = outputURL.deletingPathExtension().appendingPathExtension("chapters.csv")
        var lines = ["title,timestamp_seconds"]
        for m in markers {
            let safe = m.title.replacingOccurrences(of: "\"", with: "\"\"")
            lines.append("\"\(safe)\",\(String(format: "%.3f", m.timestamp))")
        }
        try lines.joined(separator: "\n").write(to: csvURL, atomically: true, encoding: .utf8)
    }

    /// Returns the playback duration of a WAV blob by reading its RIFF header.
    static func duration(of wavData: Data) -> TimeInterval {
        let header = parseWAVHeader(wavData)
        let pcmBytes: Int
        if let offset = findChunk(tag: "data", in: wavData) {
            pcmBytes = chunkSize(tag: "data", in: wavData, bodyStart: offset)
        } else {
            guard wavData.count > 44 else { return 0 }
            let sz: Int32 = wavData.withUnsafeBytes { $0.load(fromByteOffset: 40, as: Int32.self) }
            pcmBytes = Int(sz)
        }
        let bytesPerSecond = Int(header.sampleRate) * Int(header.channels) * Int(header.bitsPerSample) / 8
        guard bytesPerSecond > 0 else { return 0 }
        return Double(pcmBytes) / Double(bytesPerSecond)
    }

    // MARK: - WAV helpers

    private struct WAVHeader {
        let sampleRate: Int32
        let channels: Int16
        let bitsPerSample: Int16
    }

    private static func parseWAVHeader(_ data: Data) -> WAVHeader {
        // Scan for the "fmt " chunk — soundfile may insert extra chunks (e.g. "fact")
        // before "data", so fixed offsets are unreliable.
        if let fmtOffset = findChunk(tag: "fmt ", in: data), fmtOffset + 24 <= data.count {
            let ch:  Int16 = data.withUnsafeBytes { $0.load(fromByteOffset: fmtOffset + 2,  as: Int16.self) }
            let sr:  Int32 = data.withUnsafeBytes { $0.load(fromByteOffset: fmtOffset + 4,  as: Int32.self) }
            let bps: Int16 = data.withUnsafeBytes { $0.load(fromByteOffset: fmtOffset + 14, as: Int16.self) }
            return WAVHeader(sampleRate: sr, channels: ch, bitsPerSample: bps)
        }
        // Fallback: standard 44-byte layout
        let sr:  Int32 = data.withUnsafeBytes { $0.load(fromByteOffset: 24, as: Int32.self) }
        let ch:  Int16 = data.withUnsafeBytes { $0.load(fromByteOffset: 22, as: Int16.self) }
        let bps: Int16 = data.withUnsafeBytes { $0.load(fromByteOffset: 34, as: Int16.self) }
        return WAVHeader(sampleRate: sr, channels: ch, bitsPerSample: bps)
    }

    private static func extractPCM(from data: Data) -> Data {
        if let dataOffset = findChunk(tag: "data", in: data) {
            // dataOffset points to the first byte of chunk data (after the 8-byte tag+size header)
            let end = min(dataOffset + chunkSize(tag: "data", in: data, bodyStart: dataOffset), data.count)
            guard dataOffset < end else { return Data() }
            return data.subdata(in: dataOffset..<end)
        }
        // Fallback: standard 44-byte layout
        guard data.count > 44 else { return Data() }
        let size: Int32 = data.withUnsafeBytes { $0.load(fromByteOffset: 40, as: Int32.self) }
        let end = min(44 + Int(size), data.count)
        return data.subdata(in: 44..<end)
    }

    // Returns the byte offset of the first byte of chunk *body* (past the 4-byte size field).
    private static func findChunk(tag: String, in data: Data) -> Int? {
        guard data.count > 12 else { return nil }
        let tagBytes = Array(tag.utf8)
        var offset = 12  // skip RIFF/WAVE preamble
        while offset + 8 <= data.count {
            if data[offset..<offset+4].elementsEqual(tagBytes) {
                return offset + 8  // body starts after 4-byte tag + 4-byte size
            }
            let size: UInt32 = data.withUnsafeBytes { $0.load(fromByteOffset: offset + 4, as: UInt32.self) }
            offset += 8 + Int(size) + (Int(size) % 2)  // chunks are word-aligned
        }
        return nil
    }

    private static func chunkSize(tag: String, in data: Data, bodyStart: Int) -> Int {
        guard bodyStart >= 8 else { return 0 }
        let size: UInt32 = data.withUnsafeBytes { $0.load(fromByteOffset: bodyStart - 4, as: UInt32.self) }
        return Int(size)
    }

    private static func makeWAVHeader(sampleRate: Int32, channels: Int16, bitsPerSample: Int16, dataSize: Int) -> Data {
        var d = Data()
        let byteRate = Int32(sampleRate) * Int32(channels) * Int32(bitsPerSample) / 8
        let blockAlign: Int16 = channels * bitsPerSample / 8

        func u32le(_ v: UInt32) { var x = v.littleEndian; d.append(contentsOf: withUnsafeBytes(of: &x) { Array($0) }) }
        func u16le(_ v: UInt16) { var x = v.littleEndian; d.append(contentsOf: withUnsafeBytes(of: &x) { Array($0) }) }
        func str(_ s: String)   { d.append(contentsOf: s.utf8) }

        str("RIFF"); u32le(UInt32(dataSize + 36))
        str("WAVE"); str("fmt "); u32le(16)
        u16le(3)                              // IEEE float PCM
        u16le(UInt16(bitPattern: channels))
        u32le(UInt32(bitPattern: sampleRate))
        u32le(UInt32(bitPattern: byteRate))
        u16le(UInt16(bitPattern: blockAlign))
        u16le(UInt16(bitPattern: bitsPerSample))
        str("data"); u32le(UInt32(dataSize))
        return d
    }
}
