import Foundation
import PDFKit
import AppKit

struct ExtractedDocument: Sendable {
    let text: String
    let pageCount: Int?
    let sourceURL: URL
}

enum ExtractionError: LocalizedError, Sendable {
    case unsupportedFormat(String)
    case cannotOpen
    case encodingFailed

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let e): "Unsupported format: .\(e)"
        case .cannotOpen:               "Cannot open file"
        case .encodingFailed:           "Failed to detect text encoding"
        }
    }
}

struct TextExtractor {
    static func extract(from url: URL) async throws -> ExtractedDocument {
        switch url.pathExtension.lowercased() {
        case "pdf":                return try extractPDF(url)
        case "rtf", "rtfd":        return try extractRTF(url)
        case "txt", "text", "":    return try extractTXT(url)
        default:                   throw ExtractionError.unsupportedFormat(url.pathExtension)
        }
    }

    // MARK: PDF

    private static func extractPDF(_ url: URL) throws -> ExtractedDocument {
        guard let doc = PDFDocument(url: url) else { throw ExtractionError.cannotOpen }

        var text = ""
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            let pageText = page.string ?? ""
            text += pageText + "\n"
        }
        return ExtractedDocument(text: text, pageCount: doc.pageCount, sourceURL: url)
    }

    // MARK: RTF

    private static func extractRTF(_ url: URL) throws -> ExtractedDocument {
        guard let attrStr = try? NSAttributedString(
            url: url,
            options: [.documentType: NSAttributedString.DocumentType.rtf],
            documentAttributes: nil
        ) else {
            // Try RTFD
            guard let attrStr2 = try? NSAttributedString(
                url: url,
                options: [.documentType: NSAttributedString.DocumentType.rtfd],
                documentAttributes: nil
            ) else { throw ExtractionError.cannotOpen }
            return ExtractedDocument(text: attrStr2.string, pageCount: nil, sourceURL: url)
        }
        return ExtractedDocument(text: attrStr.string, pageCount: nil, sourceURL: url)
    }

    // MARK: TXT

    private static func extractTXT(_ url: URL) throws -> ExtractedDocument {
        let text: String
        if let utf8 = try? String(contentsOf: url, encoding: .utf8) {
            text = utf8
        } else if let latin1 = try? String(contentsOf: url, encoding: .isoLatin1) {
            text = latin1
        } else if let win = try? String(contentsOf: url, encoding: .windowsCP1252) {
            text = win
        } else {
            throw ExtractionError.encodingFailed
        }
        return ExtractedDocument(text: text, pageCount: nil, sourceURL: url)
    }
}
