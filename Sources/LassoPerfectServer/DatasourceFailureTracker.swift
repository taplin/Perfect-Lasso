/// A lightweight, in-process counter of datasource action failures (MySQL
/// or FileMaker) since it was last reset.
///
/// Exists because a datasource connectivity failure (e.g. FileMaker Server
/// returning a bad response) does *not* surface as an HTTP-level signal the
/// crawl-report tool can see on its own — `PerfectFileMakerLassoExecutor`/
/// `PerfectCRUDLassoExecutor` deliberately catch that class of error and
/// convert it into a recoverable Lasso error frame the *page* can inspect
/// via `error_currenterror`, not a fatal render error — so the page still
/// renders a normal `200`. `logDatasourceActionFailure` (`main.swift`) is
/// the only place this failure is ever observed today, as a `stderr`/
/// `LogCapture` line a human has to be watching. This tracker gives the
/// crawl-report loop (`Sources/LassoCrawlReport/CrawlReport.swift`'s
/// `run(...)`) an in-process signal into the same event, so its circuit
/// breaker can react to real backend distress directly instead of only
/// inferring it from per-page HTTP status codes, which — per
/// `Documentation/lasso-perfect-server.md`'s "Crawl pacing and a circuit
/// breaker" section — cannot distinguish a backend failure from an
/// ordinary, already-cataloged interpreter gap.
///
/// Deliberately not scoped to FileMaker specifically: MySQL datasource
/// failures are the same class of "backend is unhealthy" signal, and
/// `logDatasourceActionFailure` already handles both uniformly.
public actor DatasourceFailureTracker {
    private var failureCount = 0

    public init() {}

    public func recordFailure() {
        failureCount += 1
    }

    public func currentCount() -> Int {
        failureCount
    }

    /// Called at the start of a crawl run so failures from unrelated
    /// earlier browsing (or a previous crawl) don't count toward this
    /// run's threshold.
    public func reset() {
        failureCount = 0
    }
}
