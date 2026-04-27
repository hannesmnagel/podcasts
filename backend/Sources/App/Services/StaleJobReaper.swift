import Vapor
import Fluent

struct StaleJobReaper: LifecycleHandler {
    func didBoot(_ application: Application) throws {
        let db = application.db
        let logger = application.logger
        let timeoutSeconds = Environment.get("WORKER_JOB_TIMEOUT_SECONDS")
            .flatMap(Double.init) ?? 7200  // 2 hours default

        Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(300))
                let cutoff = Date().addingTimeInterval(-timeoutSeconds)
                do {
                    let stale = try await WorkerJob.query(on: db)
                        .filter(\.$status == "claimed")
                        .filter(\.$claimedAt < cutoff)
                        .all()
                    for job in stale {
                        job.status = "pending"
                        job.claimedBy = nil
                        job.claimedAt = nil
                        try await job.save(on: db)
                    }
                    if !stale.isEmpty {
                        logger.warning("Reaped \(stale.count) stale job(s) claimed before \(cutoff)")
                    }
                } catch {
                    logger.error("StaleJobReaper error: \(error)")
                }
            }
        }
    }
}
