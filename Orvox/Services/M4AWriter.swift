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

        // ── Step 3: embed chapter list in M4B ────────────────────
        print("[M4AWriter] chapterMarkers=\(chapterMarkers.count), preset=\(preset), isAudiobook=\(preset == .audiobook)")
        if !chapterMarkers.isEmpty && preset == .audiobook {
            print("[M4AWriter] → calling injectChapterTrack")
            try injectChapterTrack(chapterMarkers, into: outputURL)
            print("[M4AWriter] → injectChapterTrack finished")
        }

        // ── Step 4: sidecar CSV with chapter timestamps ───────────
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
        var lines = ["title,timestamp"]
        for m in markers {
            let safe = m.title.replacingOccurrences(of: "\"", with: "\"\"")
            lines.append("\"\(safe)\",\(hhmmss(m.timestamp))")
        }
        try lines.joined(separator: "\n").write(to: csvURL, atomically: true, encoding: .utf8)
    }

    private static func hhmmss(_ seconds: TimeInterval) -> String {
        let t = Int(max(0, seconds))
        return String(format: "%02d:%02d:%02d", t / 3600, (t % 3600) / 60, t % 60)
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

    // MARK: - Chapter track injection (Apple Books compatible)

    private static func injectChapterTrack(_ markers: [ChapterMarker], into fileURL: URL) throws {
        let fileData = try Data(contentsOf: fileURL)
        print("[inject] fileSize=\(fileData.count)")

        guard let moovOff = findMP4Atom("moov", in: fileData, from: 0, until: fileData.count) else {
            print("[inject] ✗ moov not found"); return
        }
        let moovOrigSz = Int(readU32BE(fileData, at: moovOff))
        print("[inject] moov at \(moovOff), size=\(moovOrigSz)")
        guard moovOff + moovOrigSz <= fileData.count else {
            print("[inject] ✗ moov extends past EOF"); return
        }
        var moov = fileData.subdata(in: moovOff ..< moovOff + moovOrigSz)

        // ── mvhd: timescale, duration, next track ID ─────────────
        guard let mvhdRel = findMP4Atom("mvhd", in: moov, from: 8, until: moov.count) else {
            print("[inject] ✗ mvhd not found"); return
        }
        guard mvhdRel + 108 <= moov.count else {
            print("[inject] ✗ mvhd too small (rel=\(mvhdRel))"); return
        }
        guard moov[mvhdRel + 8] == 0 else {
            print("[inject] ✗ mvhd version \(moov[mvhdRel + 8]) not supported (need 0)"); return
        }
        let movieTS    = Int(readU32BE(moov, at: mvhdRel + 20))
        let movieDurTk = Int(readU32BE(moov, at: mvhdRel + 24))
        let audioDur   = Double(movieDurTk) / Double(max(1, movieTS))
        let chapTrkID  = Int(readU32BE(moov, at: mvhdRel + 104))
        print("[inject] mvhd: timescale=\(movieTS) duration=\(movieDurTk) (\(String(format:"%.2f",audioDur))s) nextTrackID=\(chapTrkID)")

        // ── find audio trak (handler 'soun') ─────────────────────
        var audioTrakRel = -1
        var off = 8
        while off + 8 <= moov.count {
            let sz = Int(readU32BE(moov, at: off))
            guard sz >= 8, off + sz <= moov.count else { break }
            if moov[off+4 ..< off+8].elementsEqual([UInt8]("trak".utf8)),
               let mdiaRel = findMP4Atom("mdia", in: moov, from: off+8, until: off+sz) {
                let mdiaSz = Int(readU32BE(moov, at: mdiaRel))
                if let hdlrRel = findMP4Atom("hdlr", in: moov, from: mdiaRel+8,
                                              until: min(mdiaRel+mdiaSz, moov.count)),
                   hdlrRel + 20 <= moov.count,
                   moov[hdlrRel+16 ..< hdlrRel+20].elementsEqual([UInt8]("soun".utf8)) {
                    audioTrakRel = off; break
                }
            }
            off += sz
        }
        guard audioTrakRel >= 0 else {
            print("[inject] ✗ audio trak (soun) not found"); return
        }
        print("[inject] audio trak at moov[\(audioTrakRel)], size=\(Int(readU32BE(moov, at: audioTrakRel)))")

        // ── build text samples and chapter durations ──────────────
        let mediaTK = 1000
        var sttsDeltas: [Int] = []
        var textSamples: [Data] = []

        for (i, m) in markers.enumerated() {
            let nextTS = i + 1 < markers.count ? markers[i+1].timestamp : audioDur
            sttsDeltas.append(max(1, Int(round((nextTS - m.timestamp) * Double(mediaTK)))))
            var s = Data()
            let label = "\(hhmmss(m.timestamp)) \(m.title)"
            let b = [UInt8](label.utf8)
            s.append(UInt8((b.count >> 8) & 0xFF))
            s.append(UInt8( b.count       & 0xFF))
            s.append(contentsOf: b)
            textSamples.append(s)
        }
        let mediaDurTk = sttsDeltas.reduce(0, +)

        // ── inject tref/chap into audio trak ─────────────────────
        // Insert after tkhd (first child), before mdia — QuickTime spec order
        var chapIDBytes = Data()
        appendU32BE(&chapIDBytes, UInt32(chapTrkID))
        let tref = wrapAtom("tref", body: wrapAtom("chap", body: chapIDBytes))
        let audioTrakOrigSz = Int(readU32BE(moov, at: audioTrakRel))
        let tkhdSz = Int(readU32BE(moov, at: audioTrakRel + 8))
        moov.insert(contentsOf: tref, at: audioTrakRel + 8 + tkhdSz)
        writeU32BE(UInt32(audioTrakOrigSz + tref.count), into: &moov, at: audioTrakRel)

        // ── append chapter trak (stco = 0, patched below) ────────
        let chapTrak = buildChapterTrak(
            trackID: UInt32(chapTrkID), movieDuration: UInt32(movieDurTk),
            movieTS: UInt32(movieTS), mediaDuration: UInt32(mediaDurTk),
            mediaTS: UInt32(mediaTK), sttsDeltas: sttsDeltas, textSamples: textSamples
        )
        moov.append(chapTrak)

        // ── update moov size and mvhd.next_track_ID ───────────────
        writeU32BE(UInt32(moov.count), into: &moov, at: 0)
        writeU32BE(UInt32(chapTrkID + 1), into: &moov, at: mvhdRel + 104)

        // ── patch stco: chapter mdat sits right after moov ────────
        let chapMdatBodyOff = moovOff + moov.count + 8
        let chapTrakRelStart = moov.count - chapTrak.count
        if let stcoRel = findStcoInTrak(moov: moov, trakStart: chapTrakRelStart) {
            let firstEntry = stcoRel + 16   // box-hdr(8)+version+flags(4)+count(4)
            var cum = 0
            for (i, s) in textSamples.enumerated() {
                writeU32BE(UInt32(chapMdatBodyOff + cum), into: &moov, at: firstEntry + i*4)
                cum += s.count
            }
        }

        // ── chapter mdat ──────────────────────────────────────────
        var textBody = Data()
        textSamples.forEach { textBody.append($0) }
        var chapMdat = Data()
        appendU32BE(&chapMdat, UInt32(8 + textBody.count))
        chapMdat.append(contentsOf: "mdat".utf8)
        chapMdat.append(textBody)

        var result = fileData.subdata(in: 0 ..< moovOff)
        result.append(moov)
        result.append(chapMdat)

        // ── patch ftyp: M4A → M4B so AVFoundation enables chapter navigation ─
        if let ftypOff = findMP4Atom("ftyp", in: result, from: 0, until: moovOff),
           ftypOff + 12 <= result.count {
            result[ftypOff + 8]  = 0x4D  // 'M'
            result[ftypOff + 9]  = 0x34  // '4'
            result[ftypOff + 10] = 0x42  // 'B'
            result[ftypOff + 11] = 0x20  // ' '
        }

        try result.write(to: fileURL, options: .atomic)
        print("[inject] ✓ wrote \(result.count) bytes (\(markers.count) chapters, chapTrkID=\(chapTrkID))")
    }

    private static func buildChapterTrak(
        trackID: UInt32, movieDuration: UInt32, movieTS: UInt32,
        mediaDuration: UInt32, mediaTS: UInt32,
        sttsDeltas: [Int], textSamples: [Data]
    ) -> Data {
        let N = sttsDeltas.count

        // tkhd
        var tk = Data()
        appendU32BE(&tk, 0); appendU32BE(&tk, 0)        // creation/modification time
        appendU32BE(&tk, trackID); appendU32BE(&tk, 0)  // track_id, reserved
        appendU32BE(&tk, movieDuration)
        tk.append(contentsOf: repeatElement(UInt8(0), count: 8))
        appendU16BE(&tk, 0); appendU16BE(&tk, 0)        // layer, alt-group
        appendU16BE(&tk, 0); appendU16BE(&tk, 0)        // volume, reserved
        appendU32BE(&tk, 0x00010000); appendU32BE(&tk, 0); appendU32BE(&tk, 0)
        appendU32BE(&tk, 0); appendU32BE(&tk, 0x00010000); appendU32BE(&tk, 0)
        appendU32BE(&tk, 0); appendU32BE(&tk, 0); appendU32BE(&tk, 0x40000000)
        appendU32BE(&tk, 0); appendU32BE(&tk, 0)        // width, height
        let tkhd = buildFullBox("tkhd", version: 0, flags: 0x000001, body: tk)

        // mdhd
        var md = Data()
        appendU32BE(&md, 0); appendU32BE(&md, 0)
        appendU32BE(&md, mediaTS); appendU32BE(&md, mediaDuration)
        appendU16BE(&md, 0x55C4); appendU16BE(&md, 0)  // language: undetermined
        let mdhd = buildFullBox("mdhd", version: 0, flags: 0, body: md)

        // hdlr
        var hd = Data()
        appendU32BE(&hd, 0)
        hd.append(contentsOf: "text".utf8)
        hd.append(contentsOf: repeatElement(UInt8(0), count: 12))
        hd.append(contentsOf: "Chapter Handler".utf8); hd.append(0)
        let hdlr = buildFullBox("hdlr", version: 0, flags: 0, body: hd)

        // stsd → text sample description (QuickTime text format, matches AtomicParsley/mp4chaps)
        var tx = Data()
        tx.append(contentsOf: repeatElement(UInt8(0), count: 6))   // reserved
        appendU16BE(&tx, 1)                                          // data-ref index
        appendU32BE(&tx, 0)                                          // display flags = 0
        appendU32BE(&tx, 0)                                          // text justification = 0 (left)
        appendU16BE(&tx, 0xFFFF); appendU16BE(&tx, 0xFFFF); appendU16BE(&tx, 0xFFFF) // bg = white
        tx.append(contentsOf: repeatElement(UInt8(0), count: 8))    // default text box
        tx.append(contentsOf: repeatElement(UInt8(0), count: 8))    // reserved
        appendU16BE(&tx, 0); appendU16BE(&tx, 0)                    // font number, face
        tx.append(0); appendU16BE(&tx, 0)                            // reserved
        appendU16BE(&tx, 0); appendU16BE(&tx, 0); appendU16BE(&tx, 0) // fg = black
        tx.append(0)                                                  // font name "\0"
        var stsdBody = Data(); appendU32BE(&stsdBody, 1); stsdBody.append(wrapAtom("text", body: tx))
        let stsd = buildFullBox("stsd", version: 0, flags: 0, body: stsdBody)

        // stts
        var sttsBody = Data(); appendU32BE(&sttsBody, UInt32(N))
        sttsDeltas.forEach { appendU32BE(&sttsBody, 1); appendU32BE(&sttsBody, UInt32($0)) }
        let stts = buildFullBox("stts", version: 0, flags: 0, body: sttsBody)

        // stsc (one sample per chunk)
        var stscBody = Data(); appendU32BE(&stscBody, 1)
        appendU32BE(&stscBody, 1); appendU32BE(&stscBody, 1); appendU32BE(&stscBody, 1)
        let stsc = buildFullBox("stsc", version: 0, flags: 0, body: stscBody)

        // stsz
        var szBody = Data(); appendU32BE(&szBody, 0); appendU32BE(&szBody, UInt32(N))
        textSamples.forEach { appendU32BE(&szBody, UInt32($0.count)) }
        let stsz = buildFullBox("stsz", version: 0, flags: 0, body: szBody)

        // stco (zeros — patched by caller)
        var coBody = Data(); appendU32BE(&coBody, UInt32(N))
        (0..<N).forEach { _ in appendU32BE(&coBody, 0) }
        let stco = buildFullBox("stco", version: 0, flags: 0, body: coBody)

        var stblBody = Data()
        [stsd, stts, stsc, stsz, stco].forEach { stblBody.append($0) }
        let stbl = wrapAtom("stbl", body: stblBody)

        var gminBody = Data()
        appendU16BE(&gminBody, 0x0040)  // graphicsMode: ditherCopy
        appendU16BE(&gminBody, 0x8000)  // opcolor R
        appendU16BE(&gminBody, 0x8000)  // opcolor G
        appendU16BE(&gminBody, 0x8000)  // opcolor B
        appendU16BE(&gminBody, 0)       // balance
        appendU16BE(&gminBody, 0)       // reserved
        let gmhd = wrapAtom("gmhd", body: buildFullBox("gmin", version: 0, flags: 0, body: gminBody))
        let urlBox = buildFullBox("url ", version: 0, flags: 1, body: Data())
        var drefBody = Data(); appendU32BE(&drefBody, 1); drefBody.append(urlBox)
        let dinf = wrapAtom("dinf", body: buildFullBox("dref", version: 0, flags: 0, body: drefBody))

        var minfBody = Data()
        [gmhd, dinf, stbl].forEach { minfBody.append($0) }
        var mdiaBody = Data()
        [mdhd, hdlr, wrapAtom("minf", body: minfBody)].forEach { mdiaBody.append($0) }
        // edts/elst: map chapter media to movie timeline (required by AVFoundation)
        var elstBody = Data()
        appendU32BE(&elstBody, 1)               // entry_count
        appendU32BE(&elstBody, movieDuration)   // segment_duration in movie timescale
        appendU32BE(&elstBody, 0)               // media_time = 0 (start of media)
        appendU32BE(&elstBody, 0x00010000)      // media_rate = 1.0 (16.16 fixed)
        let edts = wrapAtom("edts", body: buildFullBox("elst", version: 0, flags: 0, body: elstBody))

        var trakBody = Data()
        [tkhd, edts, wrapAtom("mdia", body: mdiaBody)].forEach { trakBody.append($0) }
        return wrapAtom("trak", body: trakBody)
    }

    private static func findStcoInTrak(moov: Data, trakStart: Int) -> Int? {
        let trakEnd = trakStart + Int(readU32BE(moov, at: trakStart))
        guard let mdia = findMP4Atom("mdia", in: moov, from: trakStart+8, until: trakEnd) else { return nil }
        let mdiaEnd = mdia + Int(readU32BE(moov, at: mdia))
        guard let minf = findMP4Atom("minf", in: moov, from: mdia+8, until: mdiaEnd) else { return nil }
        let minfEnd = minf + Int(readU32BE(moov, at: minf))
        guard let stbl = findMP4Atom("stbl", in: moov, from: minf+8, until: minfEnd) else { return nil }
        let stblEnd = stbl + Int(readU32BE(moov, at: stbl))
        return findMP4Atom("stco", in: moov, from: stbl+8, until: stblEnd)
    }

    private static func buildFullBox(_ fourcc: String, version: UInt8, flags: UInt32, body: Data) -> Data {
        var fb = Data()
        fb.append(version)
        fb.append(UInt8((flags >> 16) & 0xFF))
        fb.append(UInt8((flags >>  8) & 0xFF))
        fb.append(UInt8( flags        & 0xFF))
        fb.append(body)
        return wrapAtom(fourcc, body: fb)
    }

    private static func appendU16BE(_ data: inout Data, _ v: UInt16) {
        data.append(UInt8((v >> 8) & 0xFF))
        data.append(UInt8( v       & 0xFF))
    }

    private static func appendU32BE(_ data: inout Data, _ v: UInt32) {
        data.append(UInt8((v >> 24) & 0xFF))
        data.append(UInt8((v >> 16) & 0xFF))
        data.append(UInt8((v >>  8) & 0xFF))
        data.append(UInt8( v        & 0xFF))
    }

    private static func findMP4Atom(_ fourcc: String, in data: Data, from start: Int, until limit: Int) -> Int? {
        let tag = Array(fourcc.utf8)
        var offset = start
        while offset + 8 <= limit {
            let sz32 = Int(readU32BE(data, at: offset))
            let sz: Int
            if sz32 == 1 {
                // Extended 64-bit size: 8-byte size field follows the fourcc
                guard offset + 16 <= data.count else { break }
                let hi = UInt64(readU32BE(data, at: offset + 8))
                let lo = UInt64(readU32BE(data, at: offset + 12))
                let sz64 = (hi << 32) | lo
                guard sz64 >= 16, sz64 <= UInt64(Int.max) else { break }
                sz = Int(sz64)
            } else if sz32 == 0 {
                sz = limit - offset  // atom extends to end of container
            } else {
                sz = sz32
            }
            guard sz >= 8 else { break }
            if data[offset+4..<offset+8].elementsEqual(tag) { return offset }
            offset += sz
        }
        return nil
    }

    private static func readU32BE(_ data: Data, at offset: Int) -> UInt32 {
        (UInt32(data[offset]) << 24) | (UInt32(data[offset+1]) << 16)
            | (UInt32(data[offset+2]) << 8) | UInt32(data[offset+3])
    }

    private static func writeU32BE(_ value: UInt32, into data: inout Data, at offset: Int) {
        data[offset]   = UInt8((value >> 24) & 0xFF)
        data[offset+1] = UInt8((value >> 16) & 0xFF)
        data[offset+2] = UInt8((value >>  8) & 0xFF)
        data[offset+3] = UInt8( value        & 0xFF)
    }

    private static func wrapAtom(_ fourcc: String, body: Data) -> Data {
        let size = UInt32(8 + body.count)
        var d = Data([
            UInt8((size >> 24) & 0xFF), UInt8((size >> 16) & 0xFF),
            UInt8((size >>  8) & 0xFF), UInt8( size        & 0xFF),
        ])
        d.append(contentsOf: fourcc.utf8)
        d.append(body)
        return d
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
