import Foundation
import Observation

@MainActor
@Observable
final class JobStore {
    static let shared = JobStore()

    var jobs: [Job] = []

    private init() { load() }

    func add(_ job: Job) {
        jobs.append(job)
        persist()
    }

    func update(_ job: Job) {
        guard let idx = jobs.firstIndex(where: { $0.id == job.id }) else { return }
        jobs[idx] = job
        persist()
    }

    func updateStatus(id: UUID, status: JobStatus, progress: Double? = nil,
                      outputURL: URL? = nil, errorMessage: String? = nil) {
        guard let idx = jobs.firstIndex(where: { $0.id == id }) else { return }
        if status == .converting && jobs[idx].status != .converting {
            jobs[idx].startedAt = Date()
        }
        jobs[idx].status = status
        if let p = progress      { jobs[idx].progress     = p }
        if let u = outputURL     { jobs[idx].outputURL    = u }
        if let e = errorMessage  { jobs[idx].errorMessage = e }
        if status == .done || status == .failed { jobs[idx].finishedAt = Date() }
        persist()
    }

    func updateProgress(id: UUID, progress: Double) {
        guard let idx = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[idx].progress = progress
    }

    func updateChunks(id: UUID, completed: Int, total: Int) {
        guard let idx = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[idx].chunksCompleted = completed
        jobs[idx].chunksTotal     = total
    }

    func markStarted(id: UUID, chunksTotal: Int) {
        guard let idx = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[idx].chunksTotal     = chunksTotal
        jobs[idx].chunksCompleted = 0
    }

    func updatePageCount(id: UUID, pageCount: Int) {
        guard let idx = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[idx].pageCount = pageCount
        persist()
    }

    func remove(id: UUID) {
        jobs.removeAll { $0.id == id }
        persist()
    }

    var activeJobs: [Job] { jobs.filter { $0.status == .converting } }
    var completedJobs: [Job] { jobs.filter { $0.status == .done } }

    private func persist() {
        guard let data = try? JSONEncoder().encode(jobs) else { return }
        UserDefaults.standard.set(data, forKey: "jobs_v1")
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: "jobs_v1"),
              let decoded = try? JSONDecoder().decode([Job].self, from: data) else { return }
        // Reset any mid-conversion jobs to ready on relaunch
        jobs = decoded.map { j in
            var copy = j
            if copy.status == .converting {
                copy.status           = .ready
                copy.progress         = 0
                copy.chunksCompleted  = 0
                copy.chunksTotal      = 0
                copy.startedAt        = nil
                copy.finishedAt       = nil
            }
            return copy
        }
    }
}
