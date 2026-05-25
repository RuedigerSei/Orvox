import SwiftUI

struct ConvertView: View {
    @State private var jobStore       = JobStore.shared
    @State private var voiceStore     = VoiceProfileStore.shared
    @State private var selectedPreset: AudioPreset = {
        let raw = UserDefaults.standard.string(forKey: "defaultPreset") ?? AudioPreset.audiobook.rawValue
        return AudioPreset(rawValue: raw) ?? .audiobook
    }()
    @State private var selectedVoiceID: UUID? = nil
    @State private var isRunning = false

    // Jobs belonging to this view session (not persisted ones)
    @State private var sessionJobIDs: Set<UUID> = []

    private var sessionJobs: [Job] {
        jobStore.jobs.filter { sessionJobIDs.contains($0.id) }
    }

    var body: some View {
        VStack(spacing: 12) {
            DropZoneRow { urls in addFiles(urls: urls) }

            FileQueueTable(jobs: sessionJobs) { id in
                removeJob(id: id)
            }

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

                Button("Convert") { startConversion() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(readyJobs.isEmpty || isRunning)
            }
        }
        .padding(16)
        .navigationTitle("New Conversion Job")
    }

    // MARK: - Helpers

    private var readyJobs: [Job] {
        sessionJobs.filter { $0.status == .ready }
    }

    private func addFiles(urls: [URL]) {
        for url in urls {
            let job = Job(inputURL: url, preset: selectedPreset, voiceProfileID: selectedVoiceID)
            jobStore.add(job)
            sessionJobIDs.insert(job.id)
        }
    }

    private func removeJob(id: UUID) {
        guard sessionJobs.first(where: { $0.id == id })?.status != .converting else { return }
        jobStore.remove(id: id)
        sessionJobIDs.remove(id)
    }

    private func startConversion() {
        isRunning = true
        let jobs = readyJobs
        let voiceURL: URL? = {
            guard let vid = selectedVoiceID,
                  let profile = voiceStore.profiles.first(where: { $0.id == vid })
            else { return nil }
            return voiceStore.absoluteURL(for: profile)
        }()

        Task {
            for job in jobs {
                try? await PipelineCoordinator.shared.convert(jobID: job.id, voiceProfileURL: voiceURL)
            }
            await MainActor.run { isRunning = false }
        }
    }
}
