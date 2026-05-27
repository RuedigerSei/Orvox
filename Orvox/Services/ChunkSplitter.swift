import Foundation
import NaturalLanguage

struct TextChunk: Sendable {
    let index: Int
    let text: String
    let chapterTitle: String?
}

struct ChunkSplitter {
    static let maxTokens = 400

    static func split(text: String) -> [TextChunk] {
        var result: [TextChunk] = []
        var chunkIndex = 0

        // ── Pass 1: line-level chapter detection ─────────────────────────────
        // Headings are always on their own line. Doing this before NLTokenizer
        // avoids the tokenizer splitting "1." from "The Reach of Explanations"
        // because it treats the period as a sentence terminator.

        struct Segment {
            let chapterTitle: String?   // nil = preamble or continuation
            let body: String
        }

        var segments: [Segment] = []
        var pendingTitle: String? = nil
        var bodyLines:    [String] = []

        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let heading = detectChapter(line: trimmed) {
                segments.append(Segment(chapterTitle: pendingTitle,
                                        body: bodyLines.joined(separator: "\n")))
                pendingTitle = heading
                bodyLines    = []
            } else {
                bodyLines.append(line)
            }
        }
        segments.append(Segment(chapterTitle: pendingTitle,
                                body: bodyLines.joined(separator: "\n")))

        // ── Pass 2: sentence-level accumulation within each segment ──────────
        for segment in segments {
            var parts:      [String] = []
            var tokenCount: Int      = 0
            var firstChunk           = true

            func flush() {
                guard !parts.isEmpty else { return }
                let combined = parts.joined(separator: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !combined.isEmpty else { parts = []; tokenCount = 0; return }
                let title = firstChunk ? segment.chapterTitle : nil
                result.append(TextChunk(index: chunkIndex, text: combined,
                                        chapterTitle: title))
                chunkIndex += 1
                firstChunk  = false
                parts       = []
                tokenCount  = 0
            }

            // Seed the first chunk with the chapter heading when present.
            if let heading = segment.chapterTitle {
                parts.append(heading)
                tokenCount = max(1, heading.split(separator: " ").count)
            }

            let body = segment.body
            guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                flush(); continue
            }

            let tokenizer = NLTokenizer(unit: .sentence)
            tokenizer.string = body
            tokenizer.enumerateTokens(in: body.startIndex..<body.endIndex) { range, _ in
                let sentence = String(body[range])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !sentence.isEmpty else { return true }

                // Drop decorative separators (— — —, * * *, etc.): no letters → no speech.
                guard sentence.contains(where: { $0.isLetter }) else { return true }

                let est = max(1, sentence.split(separator: " ").count)
                if tokenCount + est > maxTokens { flush() }
                parts.append(sentence)
                tokenCount += est
                return true
            }
            flush()
        }

        return result
    }

    // MARK: - Chapter heading detection

    static func detectChapter(line: String) -> String? {
        guard !line.isEmpty else { return nil }
        let patterns: [String] = [
            #"^Chapter\s+\d+"#,                                   // Chapter 1 / Chapter 1: Title
            #"^CHAPTER\s+\d+"#,                                   // CHAPTER 1
            #"^(Part|PART)\s+(\d+|[IVXLCDM]+|[A-Za-z]+)$"#,     // Part I / Part One
            #"^\d+\.\s+\S"#,                                      // 1. The Reach of Explanations
            #"^\d+\.$"#,                                           // 1. (number alone)
        ]
        for pattern in patterns {
            if line.range(of: pattern, options: .regularExpression) != nil {
                return line
            }
        }
        return nil
    }
}
