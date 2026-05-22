import Fluent
import Vapor

struct QueueMonitorController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        routes.get("queue", use: queue)
        routes.grouped("worker").get("queue", use: queue)
    }

    func queue(req: Request) async throws -> Response {
        let snapshot = try await snapshot(on: req.db)
        var headers = HTTPHeaders()
        headers.replaceOrAdd(name: .contentType, value: "text/html; charset=utf-8")
        return Response(status: .ok, headers: headers, body: .init(string: Self.renderHTML(snapshot: snapshot)))
    }

    func snapshot(on db: any Database) async throws -> QueueMonitorSnapshot {
        let timeoutSeconds = Environment.get("WORKER_JOB_TIMEOUT_SECONDS")
            .flatMap(Int.init) ?? 7_200
        let now = Date()
        let cutoff = now.addingTimeInterval(TimeInterval(-timeoutSeconds))
        let oneHourCutoff = now.addingTimeInterval(-3600)

        let jobs = try await WorkerJob.query(on: db)
            .with(\.$episode) { episode in
                episode.with(\.$podcast)
                episode.with(\.$transcripts)
            }
            .sort(\.$status, .ascending)
            .sort(\.$priority, .descending)
            .sort(\.$createdAt, .ascending)
            .all()

        let summaries = try jobs.map { job in
            try QueueMonitorJobSummary(job: job)
        }.filter { summary in
            summary.kind != "chapters" || summary.hasTranscript
        }

        let pendingJobs = summaries.filter { $0.status == "pending" }
        let claimedJobs = summaries.filter { $0.status == "claimed" }
        let staleClaimedJobs = claimedJobs.filter { $0.claimedAt.map { $0 < cutoff } ?? false }
        let completedLastHourCount = jobs.filter {
            $0.status == "completed" && (($0.completedAt ?? $0.updatedAt) ?? .distantPast) >= oneHourCutoff
        }.count
        let failedLastHourCount = jobs.filter {
            $0.status == "failed" && ($0.updatedAt ?? .distantPast) >= oneHourCutoff
        }.count

        return QueueMonitorSnapshot(
            generatedAt: now,
            watchdogTimeoutSeconds: timeoutSeconds,
            cutoff: cutoff,
            totalJobs: jobs.count,
            pendingJobs: pendingJobs,
            claimedJobs: claimedJobs,
            completedJobs: summaries.filter { $0.status == "completed" },
            failedJobs: summaries.filter { $0.status == "failed" },
            staleClaimedJobs: staleClaimedJobs,
            completedLastHourCount: completedLastHourCount,
            failedLastHourCount: failedLastHourCount
        )
    }

    static func renderHTML(snapshot: QueueMonitorSnapshot) -> String {
        let pendingRows = renderRows(jobs: snapshot.pendingJobs, emptyMessage: "No pending jobs.")
        let claimedRows = renderRows(jobs: snapshot.claimedJobs, emptyMessage: "No claimed jobs.")
        let staleBadge = snapshot.staleClaimedJobs.isEmpty ? "Healthy" : "\(snapshot.staleClaimedJobs.count) stale"
        return """
        <!doctype html>
        <html lang="en">
        <head>
            <meta charset="utf-8">
            <meta http-equiv="refresh" content="15">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <title>Queue Monitor</title>
            <style>
                :root {
                    color-scheme: light;
                    --bg: #f4f1ea;
                    --card: #ffffff;
                    --text: #1f2328;
                    --muted: #667085;
                    --border: #d7d2c8;
                    --accent: #1f5eff;
                    --good: #067647;
                    --warn: #b54708;
                }
                * { box-sizing: border-box; }
                body {
                    margin: 0;
                    font-family: ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
                    background: linear-gradient(180deg, #f8f5ef 0%, #f1ede4 100%);
                    color: var(--text);
                }
                main { max-width: 1200px; margin: 0 auto; padding: 32px 20px 48px; }
                h1, h2, h3, p { margin: 0; }
                .hero {
                    display: flex;
                    justify-content: space-between;
                    gap: 20px;
                    align-items: flex-end;
                    margin-bottom: 24px;
                }
                .eyebrow { text-transform: uppercase; letter-spacing: .12em; font-size: 12px; color: var(--muted); margin-bottom: 10px; }
                .title { font-size: clamp(32px, 4vw, 48px); line-height: 1; }
                .subtitle { color: var(--muted); margin-top: 10px; max-width: 64ch; }
                .badge {
                    display: inline-flex;
                    align-items: center;
                    gap: 8px;
                    padding: 10px 14px;
                    border-radius: 999px;
                    background: var(--card);
                    border: 1px solid var(--border);
                    box-shadow: 0 8px 24px rgba(31, 35, 40, 0.06);
                    font-weight: 600;
                }
                .summary {
                    display: grid;
                    grid-template-columns: repeat(7, minmax(0, 1fr));
                    gap: 12px;
                    margin-bottom: 22px;
                }
                .card, .panel {
                    background: var(--card);
                    border: 1px solid var(--border);
                    border-radius: 20px;
                    box-shadow: 0 12px 28px rgba(31, 35, 40, 0.05);
                }
                .card { padding: 18px; }
                .metric { font-size: 34px; line-height: 1; margin-top: 10px; }
                .label { color: var(--muted); font-size: 14px; }
                .panel { padding: 18px; margin-bottom: 18px; overflow: hidden; }
                .panel-head {
                    display: flex;
                    justify-content: space-between;
                    align-items: baseline;
                    gap: 12px;
                    margin-bottom: 14px;
                }
                .panel-head p { color: var(--muted); font-size: 14px; }
                table { width: 100%; border-collapse: collapse; }
                th, td {
                    text-align: left;
                    border-top: 1px solid var(--border);
                    padding: 12px 8px;
                    vertical-align: top;
                    font-size: 14px;
                }
                th { color: var(--muted); font-weight: 600; border-top: 0; }
                .mono { font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace; font-size: 12px; }
                .status-pending { color: var(--accent); font-weight: 600; }
                .status-claimed { color: var(--warn); font-weight: 600; }
                .status-completed { color: var(--good); font-weight: 600; }
                .status-failed { color: #b42318; font-weight: 600; }
                .empty {
                    padding: 22px 8px;
                    color: var(--muted);
                }
                .pill {
                    display: inline-flex;
                    align-items: center;
                    padding: 6px 10px;
                    border-radius: 999px;
                    background: rgba(31, 94, 255, 0.08);
                    color: var(--accent);
                    font-size: 12px;
                    font-weight: 700;
                }
                @media (max-width: 980px) {
                    .summary { grid-template-columns: repeat(2, minmax(0, 1fr)); }
                    .hero { flex-direction: column; align-items: flex-start; }
                }
                @media (max-width: 640px) {
                    main { padding: 20px 12px 36px; }
                    .summary { grid-template-columns: 1fr; }
                    .panel { padding: 14px; }
                    table, thead, tbody, th, td, tr { display: block; }
                    thead { display: none; }
                    tr { border-top: 1px solid var(--border); padding: 10px 0; }
                    td { border: 0; padding: 4px 0; }
                }
            </style>
        </head>
        <body>
            <main>
                <section class="hero">
                    <div>
                        <div class="eyebrow">The Podcatcher backend</div>
                        <h1 class="title">Queue Monitor</h1>
                        <p class="subtitle">Live queue view for worker jobs, including pending work, claimed jobs, and stale-claim watchdog coverage.</p>
                    </div>
                    <div class="badge">
                        <span class="pill">Updated</span>
                        <span>\(Self.displayDate(snapshot.generatedAt))</span>
                    </div>
                </section>

                <section class="summary">
                    \(metricCard(label: "Total jobs", value: snapshot.totalJobs, hint: "All worker jobs in the backend"))
                    \(metricCard(label: "Pending", value: snapshot.pendingJobs.count, hint: "Ready to be claimed"))
                    \(metricCard(label: "Claimed", value: snapshot.claimedJobs.count, hint: "Currently owned by a worker"))
                    \(metricCard(label: "Completed", value: snapshot.completedJobs.count, hint: "Finished jobs"))
                    \(metricCard(label: "Completed 1h", value: snapshot.completedLastHourCount, hint: "Completed in the last hour"))
                    \(metricCard(label: "Failed 1h", value: snapshot.failedLastHourCount, hint: "Failed in the last hour"))
                    \(metricCard(label: "Watchdog", value: snapshot.staleClaimedJobs.count, hint: "Claimed longer than \(snapshot.watchdogTimeoutSeconds)s"))
                </section>

                <section class="panel">
                    <div class="panel-head">
                        <div>
                            <h2>Watchdog</h2>
                            <p>Backend lifecycle reaper sweeps claimed jobs every 5 minutes and releases jobs claimed before <span class="mono">\(Self.displayDate(snapshot.cutoff))</span>.</p>
                        </div>
                        <span class="pill">\(staleBadge)</span>
                    </div>
                    <table>
                        <tbody>
                            <tr><th>Stale claim timeout</th><td>\(snapshot.watchdogTimeoutSeconds) seconds</td></tr>
                            <tr><th>Stale claimed jobs</th><td>\(snapshot.staleClaimedJobs.count)</td></tr>
                            <tr><th>Failed jobs</th><td>\(snapshot.failedJobs.count)</td></tr>
                            <tr><th>Completed last hour</th><td>\(snapshot.completedLastHourCount)</td></tr>
                            <tr><th>Failed last hour</th><td>\(snapshot.failedLastHourCount)</td></tr>
                        </tbody>
                    </table>
                </section>

                <section class="panel">
                    <div class="panel-head">
                        <div>
                            <h2>Pending Queue</h2>
                            <p>Highest-priority jobs appear first.</p>
                        </div>
                        <span class="pill">\(snapshot.pendingJobs.count)</span>
                    </div>
                    \(pendingRows)
                </section>

                <section class="panel">
                    <div class="panel-head">
                        <div>
                            <h2>Claimed Queue</h2>
                            <p>Jobs currently being processed by a worker.</p>
                        </div>
                        <span class="pill">\(snapshot.claimedJobs.count)</span>
                    </div>
                    \(claimedRows)
                </section>
            </main>
        </body>
        </html>
        """
    }

    private static func metricCard(label: String, value: Int, hint: String) -> String {
        """
        <article class="card">
            <div class="label">\(label.htmlEscaped)</div>
            <div class="metric">\(value)</div>
            <div class="label" style="margin-top: 10px;">\(hint.htmlEscaped)</div>
        </article>
        """
    }

    private static func renderRows(jobs: [QueueMonitorJobSummary], emptyMessage: String) -> String {
        guard jobs.isEmpty == false else {
            return "<div class=\"empty\">\(emptyMessage.htmlEscaped)</div>"
        }

        let rows = jobs.map { job in
            """
            <tr>
                <td>
                    <div><strong>\(job.podcastTitle.htmlEscaped)</strong></div>
                    <div>\(job.episodeTitle.htmlEscaped)</div>
                </td>
                <td class="mono">\(job.id.uuidString)</td>
                <td class="status-\(job.status)">\(job.status.htmlEscaped)</td>
                <td>\(job.kind.htmlEscaped)</td>
                <td>\(job.priority)</td>
                <td>\(job.claimedBy?.htmlEscaped ?? "—")</td>
                <td>\(job.claimedAt.map(Self.displayDate) ?? "—")</td>
            </tr>
            """
        }.joined(separator: "")

        return """
        <table>
            <thead>
                <tr>
                    <th>Episode</th>
                    <th>ID</th>
                    <th>Status</th>
                    <th>Kind</th>
                    <th>Priority</th>
                    <th>Worker</th>
                    <th>Claimed At</th>
                </tr>
            </thead>
            <tbody>
                \(rows)
            </tbody>
        </table>
        """
    }

    private static func displayDate(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .standard)
    }
}

struct QueueMonitorSnapshot {
    let generatedAt: Date
    let watchdogTimeoutSeconds: Int
    let cutoff: Date
    let totalJobs: Int
    let pendingJobs: [QueueMonitorJobSummary]
    let claimedJobs: [QueueMonitorJobSummary]
    let completedJobs: [QueueMonitorJobSummary]
    let failedJobs: [QueueMonitorJobSummary]
    let staleClaimedJobs: [QueueMonitorJobSummary]
    let completedLastHourCount: Int
    let failedLastHourCount: Int
}

struct QueueMonitorJobSummary {
    let id: UUID
    let kind: String
    let status: String
    let priority: Int
    let hasTranscript: Bool
    let claimedBy: String?
    let claimedAt: Date?
    let podcastTitle: String
    let episodeTitle: String

    init(job: WorkerJob) throws {
        self.id = try job.requireID()
        self.kind = job.kind
        self.status = job.status
        self.priority = job.priority
        self.hasTranscript = !(job.episode.$transcripts.value?.isEmpty ?? true)
        self.claimedBy = job.claimedBy
        self.claimedAt = job.claimedAt
        self.podcastTitle = job.episode.$podcast.value?.title ?? "Unknown podcast"
        self.episodeTitle = job.episode.title
    }
}

private extension String {
    var htmlEscaped: String {
        self
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
}
