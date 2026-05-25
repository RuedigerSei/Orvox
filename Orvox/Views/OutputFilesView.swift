import SwiftUI

struct OutputFilesView: View {
    @State private var store = JobStore.shared

    private var completed: [Job] {
        store.completedJobs.sorted { $0.createdAt > $1.createdAt }
    }

    var body: some View {
        Group {
            if completed.isEmpty {
                ContentUnavailableView(
                    "No Output Files",
                    systemImage: "checkmark.circle",
                    description: Text("Completed conversions will appear here.")
                )
            } else {
                List(completed) { job in
                    OutputFileRow(job: job)
                        .listRowSeparator(.visible)
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("Output Files")
    }
}

struct OutputFileRow: View {
    let job: Job

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "music.note.list")
                .font(.system(size: 22))
                .foregroundStyle(Color.accentColor)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 3) {
                Text(outputName)
                    .font(.system(size: 13, weight: .medium))
                HStack(spacing: 10) {
                    if let pages = job.pageCount {
                        Text("\(pages) pages")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text(job.preset.displayName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(job.createdAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Button("Reveal") {
                if let url = job.outputURL {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            }
            .buttonStyle(.borderless)
            .controlSize(.small)

            Button("Open in Books") {
                if let url = job.outputURL {
                    NSWorkspace.shared.open(url)
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.vertical, 6)
    }

    private var outputName: String {
        job.outputURL?.lastPathComponent ?? job.inputURL.deletingPathExtension().lastPathComponent + ".m4a"
    }
}
