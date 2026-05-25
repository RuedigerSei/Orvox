import SwiftUI

struct JobQueueView: View {
    @State private var store      = JobStore.shared
    @State private var voiceStore = VoiceProfileStore.shared
    @State private var selection: Set<UUID> = []
    @State private var isConverting = false
    @State private var selectedPreset: AudioPreset = {
        let raw = UserDefaults.standard.string(forKey: "defaultPreset") ?? AudioPreset.audiobook.rawValue
        return AudioPreset(rawValue: raw) ?? .audiobook
    }()
    @State private var selectedVoiceID: UUID? = nil

    var body: some View {
        VStack(spacing: 0) {
            // ── Drop zone ──────────────────────────────────────────
            DropZoneRow { urls in addFiles(urls: urls) }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 10)

            // ── Job list ───────────────────────────────────────────
            if store.jobs.isEmpty {
                ContentUnavailableView(
                    "No Jobs Yet",
                    systemImage: "list.bullet.clipboard",
                    description: Text("Drop files above to start converting.")
                )
                .frame(maxHeight: .infinity)
            } else {
                List(Array(store.jobs.reversed()), id: \.id, selection: $selection) { job in
                    JobRowView(job: job)
                        .listRowSeparator(.visible)
                }
                .listStyle(.plain)
            }

            Divider()

            // ── Bottom controls ────────────────────────────────────
            HStack(spacing: 10) {
                Picker("", selection: $selectedPreset) {
                    ForEach(AudioPreset.allCases) { p in
                        Text(p.displayName).tag(p)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 230)
                .labelsHidden()

                Picker("", selection: $selectedVoiceID) {
                    Text("Voice: Default").tag(Optional<UUID>(nil))
                    Divider()
                    ForEach(voiceStore.profiles.filter { !$0.isBuiltIn }) { p in
                        Text(p.name).tag(Optional(p.id))
                    }
                }
                .frame(width: 180)
                .labelsHidden()

                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .navigationTitle("Job Queue")
        .toolbar {
            ToolbarItemGroup {
                Button(role: .destructive, action: deleteSelected) {
                    Image(systemName: "trash")
                }
                .help("Delete selected jobs")
                .disabled(deletableSelection.isEmpty)

                Divider()

                Button("Clear Completed", action: clearCompleted)
                    .disabled(store.jobs.allSatisfy { $0.status != .done && $0.status != .failed })

                Button("Convert", action: convertReady)
                    .buttonStyle(.borderedProminent)
                    .disabled(readyJobsToConvert.isEmpty || isConverting)
            }
        }
    }

    // MARK: - Derived state

    private var deletableSelection: [UUID] {
        selection.filter { id in
            store.jobs.first { $0.id == id }?.status != .converting
        }
    }

    private var readyJobsToConvert: [Job] {
        let ids: Set<UUID> = selection.isEmpty ? Set(store.jobs.map(\.id)) : selection
        return store.jobs.filter { ids.contains($0.id) && $0.status == .ready }
    }

    // MARK: - Actions

    private func addFiles(urls: [URL]) {
        for url in urls {
            store.add(Job(inputURL: url, preset: selectedPreset, voiceProfileID: selectedVoiceID))
        }
    }

    private func deleteSelected() {
        deletableSelection.forEach { store.remove(id: $0) }
        selection.removeAll()
    }

    private func clearCompleted() {
        store.jobs
            .filter { $0.status == .done || $0.status == .failed }
            .forEach { store.remove(id: $0.id) }
    }

    private func convertReady() {
        isConverting = true
        let jobs = readyJobsToConvert
        Task {
            for job in jobs {
                let voiceURL: URL? = {
                    guard let vid = job.voiceProfileID,
                          let profile = voiceStore.profiles.first(where: { $0.id == vid })
                    else { return nil }
                    return voiceStore.absoluteURL(for: profile)
                }()
                try? await PipelineCoordinator.shared.convert(jobID: job.id, voiceProfileURL: voiceURL)
            }
            await MainActor.run { isConverting = false }
        }
    }
}

// MARK: - Row

struct JobRowView: View {
    let job: Job

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: iconName)
                    .foregroundStyle(.secondary)
                Text(job.inputURL.lastPathComponent)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                if job.status == .converting {
                    Button("Cancel") {
                        Task { await PipelineCoordinator.shared.cancel(jobID: job.id) }
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .foregroundStyle(.red)
                }
                StatusBadge(status: job.status)
            }

            if job.status == .converting {
                ProgressView(value: job.progress > 0 ? job.progress : nil)
                    .tint(.orange)
                HStack(spacing: 10) {
                    if job.progress > 0 {
                        Text(String(format: "%.0f%%", job.progress * 100))
                    } else {
                        Text("Synthesizing…")
                    }
                    if job.chunksTotal > 0 {
                        Text("· Chunk \(job.chunksCompleted)/\(job.chunksTotal)")
                    }
                    Spacer()
                    if let start = job.startedAt {
                        ElapsedTimerText(start: start)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            if (job.status == .done || job.status == .failed),
               let start = job.startedAt, let finish = job.finishedAt {
                Text("Took \(elapsedString(from: start, to: finish))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if job.status == .failed, let msg = job.errorMessage {
                Text(msg)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack(spacing: 12) {
                if let pages = job.pageCount {
                    Label("\(pages) pages", systemImage: "doc")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(job.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()

                if job.status == .done {
                    Button("Reveal") { revealInFinder(job.outputURL) }
                        .buttonStyle(.borderless)
                        .font(.caption)
                    Button("Open") { open(job.outputURL) }
                        .buttonStyle(.borderless)
                        .font(.caption)
                }
                if job.status == .failed {
                    Button("Retry") { retry(job) }
                        .buttonStyle(.borderless)
                        .font(.caption)
                }
            }
        }
        .padding(.vertical, 6)
    }

    private func elapsedString(since start: Date) -> String {
        elapsedString(from: start, to: Date())
    }

    private func elapsedString(from start: Date, to end: Date) -> String {
        let s = max(0, Int(end.timeIntervalSince(start)))
        return s < 60 ? "\(s)s" : String(format: "%d:%02d", s / 60, s % 60)
    }

    private var iconName: String {
        switch job.inputURL.pathExtension.lowercased() {
        case "pdf":          "doc.richtext"
        case "rtf", "rtfd": "doc.text"
        default:             "doc.plaintext"
        }
    }

    private func revealInFinder(_ url: URL?) {
        guard let url else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func open(_ url: URL?) {
        guard let url else { return }
        NSWorkspace.shared.open(url)
    }

    private func retry(_ job: Job) {
        var updated = job
        updated.status = .ready
        updated.progress = 0
        updated.errorMessage = nil
        JobStore.shared.update(updated)
    }
}

// MARK: - Elapsed timer

private struct ElapsedTimerText: View {
    let start: Date
    @State private var elapsed: Int = 0

    var body: some View {
        Text(formatted)
            .task {
                elapsed = max(0, Int(Date().timeIntervalSince(start)))
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1))
                    elapsed = max(0, Int(Date().timeIntervalSince(start)))
                }
            }
    }

    private var formatted: String {
        elapsed < 60 ? "\(elapsed)s" : String(format: "%d:%02d", elapsed / 60, elapsed % 60)
    }
}

// MARK: - Status badge

struct StatusBadge: View {
    let status: JobStatus

    var body: some View {
        Text(status.rawValue)
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.15))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }

    private var color: Color {
        switch status {
        case .ready:      .blue
        case .converting: .orange
        case .done:       .green
        case .failed:     .red
        }
    }
}
