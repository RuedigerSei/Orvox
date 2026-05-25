import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - SwiftUI wrapper

struct DropZoneRow: View {
    let onAdd: ([URL]) -> Void
    @State private var isDragOver = false

    var body: some View {
        DropZoneRepresentable(isDragOver: $isDragOver, onAdd: onAdd)
            .frame(height: 34)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(
                        isDragOver ? Color.accentColor : Color.secondary.opacity(0.35),
                        style: StrokeStyle(lineWidth: 1.5, dash: [5, 3])
                    )
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(isDragOver ? Color.accentColor.opacity(0.07) : Color.clear)
                    )
            )
            .animation(.easeInOut(duration: 0.15), value: isDragOver)
    }
}

// MARK: - NSViewRepresentable bridge

struct DropZoneRepresentable: NSViewRepresentable {
    @Binding var isDragOver: Bool
    let onAdd: ([URL]) -> Void

    func makeNSView(context: Context) -> DropZoneNSView {
        DropZoneNSView()
    }

    func updateNSView(_ nsView: DropZoneNSView, context: Context) {
        // Re-bind on every SwiftUI update so closures always capture current values.
        // Binding<Bool> holds a reference to underlying storage — safe to capture by value.
        let binding = $isDragOver
        let add     = onAdd
        nsView.onDrop       = { urls in add(urls) }
        nsView.onHoverState = { active in
            DispatchQueue.main.async { binding.wrappedValue = active }
        }
    }
}

// MARK: - AppKit view

final class DropZoneNSView: NSView {
    var onDrop: (([URL]) -> Void)?
    var onHoverState: ((Bool) -> Void)?

    private let iconView = NSImageView()
    private let label    = NSTextField(labelWithString: "Drop PDF, RTF or TXT here, or click to browse…")
    private var trackingArea: NSTrackingArea?

    override init(frame: NSRect) {
        super.init(frame: frame)
        setup()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func setup() {
        registerForDraggedTypes([.fileURL])

        iconView.image = NSImage(systemSymbolName: "doc", accessibilityDescription: "document")
        iconView.contentTintColor = .tertiaryLabelColor
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.setContentHuggingPriority(.required, for: .horizontal)
        iconView.widthAnchor.constraint(equalToConstant: 16).isActive = true

        label.font = .systemFont(ofSize: 11.5)
        label.textColor = .tertiaryLabelColor
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let stack = NSStackView(views: [iconView, label])
        stack.orientation = .horizontal
        stack.alignment   = .centerY
        stack.spacing     = 8
        stack.edgeInsets  = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        let cursor = NSCursor.pointingHand
        addCursorRect(bounds, cursor: cursor)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingArea.map { removeTrackingArea($0) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .activeInKeyWindow],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { onHoverState?(true) }
    override func mouseExited(with event: NSEvent)  { onHoverState?(false) }

    override func mouseUp(with event: NSEvent) { openPanel() }

    private func openPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles        = true
        panel.canChooseDirectories  = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes   = acceptedTypes()
        guard panel.runModal() == .OK else { return }
        onDrop?(panel.urls)
    }

    // MARK: Drag

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let valid = filteredURLs(from: sender).count > 0
        onHoverState?(valid)
        return valid ? .copy : []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { onHoverState?(false) }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = filteredURLs(from: sender)
        onHoverState?(false)
        guard !urls.isEmpty else { return false }
        onDrop?(urls)
        return true
    }

    private func filteredURLs(from info: NSDraggingInfo) -> [URL] {
        let items = info.draggingPasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] ?? []
        return items.filter { accepted(url: $0) }
    }

    private func accepted(url: URL) -> Bool {
        ["pdf", "rtf", "rtfd", "txt", "text"].contains(url.pathExtension.lowercased())
    }

    private func acceptedTypes() -> [UTType] {
        var types: [UTType] = [.pdf, .rtf, .plainText]
        if let rtfd = UTType("com.apple.rtfd") { types.append(rtfd) }
        return types
    }
}
