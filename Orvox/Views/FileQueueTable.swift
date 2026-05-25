import SwiftUI
import AppKit

// MARK: - SwiftUI wrapper

struct FileQueueTable: View {
    let jobs: [Job]
    let onRemove: (UUID) -> Void

    var body: some View {
        FileQueueNSTable(jobs: jobs, onRemove: onRemove)
            .frame(minHeight: 120)
    }
}

// MARK: - Custom NSTableView (handles ⌫ deletion)

private final class DeleteAwareTableView: NSTableView {
    var onDeleteSelected: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 51 {   // ⌫
            onDeleteSelected?()
        } else {
            super.keyDown(with: event)
        }
    }
}

// MARK: - NSViewRepresentable

struct FileQueueNSTable: NSViewRepresentable {
    let jobs: [Job]
    let onRemove: (UUID) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> NSScrollView {
        let tv = DeleteAwareTableView()
        tv.style = .automatic
        tv.usesAlternatingRowBackgroundColors = true
        tv.rowHeight = 32
        tv.delegate   = context.coordinator
        tv.dataSource = context.coordinator
        tv.allowsMultipleSelection = true

        tv.onDeleteSelected = { [weak tv, weak coordinator = context.coordinator] in
            guard let tv, let coordinator else { return }
            let indices = tv.selectedRowIndexes
            let ids = indices.compactMap { i -> UUID? in
                i < coordinator.parent.jobs.count ? coordinator.parent.jobs[i].id : nil
            }
            ids.forEach { coordinator.parent.onRemove($0) }
        }

        let cols: [(id: String, title: String, width: CGFloat, flex: Bool)] = [
            ("icon",     "",         26,  false),
            ("name",     "File",    180,  true),
            ("pages",    "Pages",    52,  false),
            ("status",   "Status",   90,  false),
            ("progress", "Progress", 120, true),
        ]
        for spec in cols {
            let col = NSTableColumn(identifier: .init(spec.id))
            col.title = spec.title
            if spec.flex {
                col.resizingMask = .autoresizingMask
                col.minWidth = spec.width
            } else {
                col.resizingMask = []
                col.width = spec.width
                col.minWidth = spec.width
                col.maxWidth = spec.width
            }
            tv.addTableColumn(col)
        }
        tv.sizeToFit()

        context.coordinator.tableView = tv

        let scroll = NSScrollView()
        scroll.documentView     = tv
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers  = true
        scroll.borderType = .noBorder
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.tableView?.reloadData()
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, NSTableViewDelegate, NSTableViewDataSource {
        var parent: FileQueueNSTable
        weak var tableView: NSTableView?

        init(parent: FileQueueNSTable) { self.parent = parent }

        func numberOfRows(in tableView: NSTableView) -> Int { parent.jobs.count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard row < parent.jobs.count else { return nil }
            let job = parent.jobs[row]

            switch tableColumn?.identifier.rawValue {
            case "icon":
                let iv = NSImageView()
                iv.image = iconForExt(job.inputURL.pathExtension)
                iv.imageScaling = .scaleProportionallyUpOrDown
                return iv

            case "name":
                return label(job.inputURL.lastPathComponent, size: 12)

            case "pages":
                let text = job.pageCount.map { "\($0)" } ?? "—"
                return label(text, size: 11, color: .secondaryLabelColor, mono: true)

            case "status":
                return label(job.status.rawValue, size: 10.5, weight: .semibold, color: colorFor(job.status))

            case "progress":
                if job.status == .converting {
                    let bar = NSProgressIndicator()
                    if job.progress > 0 {
                        bar.style           = .bar
                        bar.isIndeterminate = false
                        bar.minValue        = 0
                        bar.maxValue        = 1
                        bar.doubleValue     = job.progress
                    } else {
                        bar.style           = .spinning
                        bar.isIndeterminate = true
                        bar.startAnimation(nil)
                    }
                    // Wrap in a stack with chunk counter if available
                    if job.chunksTotal > 0 {
                        let stack = NSStackView(views: [bar,
                            label("\(job.chunksCompleted)/\(job.chunksTotal)",
                                  size: 9, color: .secondaryLabelColor, mono: true)])
                        stack.orientation = .horizontal
                        stack.spacing     = 4
                        stack.alignment   = .centerY
                        return stack
                    }
                    return bar
                }
                if job.status == .done {
                    return label("✓", size: 12, color: .systemGreen)
                }
                if job.status == .failed {
                    return label(job.errorMessage ?? "Error", size: 10, color: .systemRed)
                }
                return nil

            default: return nil
            }
        }

        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { 32 }

        // MARK: helpers

        private func label(_ text: String, size: CGFloat,
                           weight: NSFont.Weight = .regular,
                           color: NSColor = .labelColor,
                           mono: Bool = false) -> NSTextField {
            let tf = NSTextField(labelWithString: text)
            tf.font = mono
                ? .monospacedDigitSystemFont(ofSize: size, weight: weight)
                : .systemFont(ofSize: size, weight: weight)
            tf.textColor     = color
            tf.lineBreakMode = .byTruncatingMiddle
            return tf
        }

        private func iconForExt(_ ext: String) -> NSImage? {
            let name: String
            switch ext.lowercased() {
            case "pdf":          name = "doc.richtext"
            case "rtf", "rtfd": name = "doc.text"
            default:             name = "doc.plaintext"
            }
            return NSImage(systemSymbolName: name, accessibilityDescription: nil)
        }

        private func colorFor(_ status: JobStatus) -> NSColor {
            switch status {
            case .ready:      .systemBlue
            case .converting: .systemOrange
            case .done:       .systemGreen
            case .failed:     .systemRed
            }
        }
    }
}
