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
        var currentParts: [String] = []
        var currentTokenCount = 0
        var currentChapterTitle: String? = nil

        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text

        func flush() {
            guard !currentParts.isEmpty else { return }
            let combined = currentParts.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            if !combined.isEmpty {
                result.append(TextChunk(index: chunkIndex, text: combined, chapterTitle: currentChapterTitle))
                chunkIndex += 1
            }
            currentParts = []
            currentTokenCount = 0
        }

        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let sentence = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !sentence.isEmpty else { return true }

            // Check each line of the sentence for a chapter heading
            let lines = sentence.components(separatedBy: .newlines)
            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if let chapter = detectChapter(line: trimmed) {
                    flush()
                    currentChapterTitle = chapter
                    return true
                }
            }

            let tokenEstimate = max(1, sentence.split(separator: " ").count)
            if currentTokenCount + tokenEstimate > maxTokens {
                flush()
            }

            currentParts.append(sentence)
            currentTokenCount += tokenEstimate
            return true
        }
        flush()
        return result
    }

    static func detectChapter(line: String) -> String? {
        guard !line.isEmpty else { return nil }
        let patterns: [String] = [
            #"^Chapter\s+\d+"#,           // Chapter N or Chapter N: Title
            #"^CHAPTER\s+\d+"#,           // CHAPTER N
            #"^(Part|PART)\s+(\d+|[IVXLCDM]+|[A-Za-z]+)$"#,
            #"^\d+\.\s+\S"#,              // N. Title (heading with text)
            #"^\d+\.$"#,                  // N. alone on a line
        ]
        for pattern in patterns {
            if line.range(of: pattern, options: .regularExpression) != nil {
                return line
            }
        }
        return nil
    }
}
