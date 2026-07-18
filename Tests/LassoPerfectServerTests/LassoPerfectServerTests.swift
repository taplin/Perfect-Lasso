import Foundation
import Testing
@testable import LassoPerfectServer
import LassoParser
import PerfectAdminConsole
import PerfectNIO

// See Documentation/web-response-include-plan.md. Covers the pure
// header-building helpers behind sendFile/file_serve/file_stream's
// response construction — specifically the CRLF-stripping and
// quoted-string-escaping fix that a code review pass flagged as having no
// automated coverage (LassoParserTests can't reach LassoPerfectServer's
// executable target, hence this separate test target).

@Test func headerSafeStripsCarriageReturnsAndNewlines() {
    #expect(headerSafe("text/plain\r\nX-Injected: evil") == "text/plainX-Injected: evil")
    #expect(headerSafe("no newlines here") == "no newlines here")
}

@Test func quotedStringSafeEscapesBackslashAndDoubleQuoteAndStripsCRLF() {
    // Backslash must be escaped first — escaping the quote before the
    // backslash would double-escape the backslash it just inserted.
    #expect(quotedStringSafe(#"evil".pdf"#) == #"evil\".pdf"#)
    #expect(quotedStringSafe(#"a\b"#) == #"a\\b"#)
    #expect(quotedStringSafe("line1\r\nline2") == "line1line2")
    #expect(quotedStringSafe("plain.pdf") == "plain.pdf")
}

@Test func bytesFileOutputSetsContentTypeAndOmitsDispositionWhenNil() throws {
    let request = LassoFileServeRequest(source: .data(Data("hello".utf8)), contentType: "text/plain")
    let output = bytesFileOutput(data: Data("hello".utf8), request: request)

    let head = try #require(output.head(request: sampleRequestInfo()))
    #expect(head.headers.first(name: "Content-Type") == "text/plain")
    #expect(head.headers.first(name: "Content-Disposition") == nil)
}

@Test func bytesFileOutputBuildsDispositionWithEscapedFilenameWhenNameGiven() throws {
    let request = LassoFileServeRequest(
        source: .data(Data("hello".utf8)),
        fileName: #"report".pdf"#,
        contentType: "application/pdf",
        disposition: "attachment"
    )
    let output = bytesFileOutput(data: Data("hello".utf8), request: request)

    let head = try #require(output.head(request: sampleRequestInfo()))
    #expect(head.headers.first(name: "Content-Type") == "application/pdf")
    #expect(head.headers.first(name: "Content-Disposition") == #"attachment; filename="report\".pdf""#)
}

@Test func bytesFileOutputOmitsFilenameAttributeWhenNoNameGiven() throws {
    // file_serve/file_stream's shape: a disposition-free override branch
    // (contentType set, name/disposition both nil) must not emit a
    // Content-Disposition header at all.
    let request = LassoFileServeRequest(source: .path("downloads/report.pdf"), contentType: "application/pdf")
    let output = bytesFileOutput(data: Data("hello".utf8), request: request)

    let head = try #require(output.head(request: sampleRequestInfo()))
    #expect(head.headers.first(name: "Content-Disposition") == nil)
}

@Test func bytesFileOutputDefaultsContentTypeToOctetStreamWhenNil() throws {
    let request = LassoFileServeRequest(source: .data(Data("hello".utf8)))
    let output = bytesFileOutput(data: Data("hello".utf8), request: request)

    let head = try #require(output.head(request: sampleRequestInfo()))
    #expect(head.headers.first(name: "Content-Type") == "application/octet-stream")
}

private func sampleRequestInfo() -> HTTPRequestInfo {
    HTTPRequestInfo(
        head: HTTPRequestHead(version: .http1_1, method: .GET, uri: "/"),
        options: []
    )
}

// MARK: - DatasourceFileConfig / DatasourceEntry decoding
//
// See Documentation/lasso-perfect-server.md's FileMaker Datasource
// section. `datasources` used to be a flat `[String: String]` (Lasso
// alias -> MySQL schema name); it's now `[String: DatasourceEntry]` so a
// config file can mix MySQL and FileMaker aliases, but every config file
// written before FileMaker support must keep decoding identically.

@Test func datasourceEntryDecodesLegacyBareStringAsMySQLWithSchema() throws {
    let entry = try JSONDecoder().decode(DatasourceEntry.self, from: Data(#""catalog""#.utf8))
    #expect(entry.type == .mysql)
    #expect(entry.schema == "catalog")
}

@Test func datasourceEntryDecodesExplicitMySQLObjectShape() throws {
    let entry = try JSONDecoder().decode(
        DatasourceEntry.self,
        from: Data(#"{"type": "mysql", "schema": "catalog"}"#.utf8)
    )
    #expect(entry.type == .mysql)
    #expect(entry.schema == "catalog")
}

@Test func datasourceEntryDecodesFileMakerObjectShapeWithNoSchema() throws {
    let entry = try JSONDecoder().decode(DatasourceEntry.self, from: Data(#"{"type": "filemaker"}"#.utf8))
    #expect(entry.type == .filemaker)
    #expect(entry.schema == nil)
    #expect(entry.host == nil)
    #expect(entry.port == nil)
}

@Test func datasourceEntryDecodesFileMakerHostPortOverride() throws {
    // A second FileMaker alias pointing at a different server (e.g. a
    // dev/backup instance) while reusing the shared filemaker block's
    // credentials -- see ServerConfig.filemakerHostOverrides.
    let entry = try JSONDecoder().decode(
        DatasourceEntry.self,
        from: Data(#"{"type": "filemaker", "host": "203.0.113.5", "port": 8080}"#.utf8)
    )
    #expect(entry.type == .filemaker)
    #expect(entry.host == "203.0.113.5")
    #expect(entry.port == 8080)
}

@Test func datasourceEntryLegacyBareStringHasNoHostOverride() throws {
    let entry = try JSONDecoder().decode(DatasourceEntry.self, from: Data(#""catalog""#.utf8))
    #expect(entry.host == nil)
    #expect(entry.port == nil)
}

@Test func datasourceFileConfigDecodesLegacyFlatShapeAsMySQLBlock() throws {
    let json = """
    {
        "host": "localhost",
        "port": 3306,
        "user": "lassouser",
        "password": "secret",
        "sessionDatabase": "sessions",
        "allowWrites": true,
        "allowRawSQL": false,
        "datasources": {"catalog_mysql": "catalog"}
    }
    """
    let config = try JSONDecoder().decode(DatasourceFileConfig.self, from: Data(json.utf8))
    #expect(config.mysql?.host == "localhost")
    #expect(config.mysql?.port == 3306)
    #expect(config.mysql?.user == "lassouser")
    #expect(config.mysql?.password == "secret")
    #expect(config.mysql?.sessionDatabase == "sessions")
    #expect(config.mysql?.allowWrites == true)
    #expect(config.mysql?.allowRawSQL == false)
    #expect(config.filemaker == nil)
    #expect(config.datasources["catalog_mysql"]?.type == .mysql)
    #expect(config.datasources["catalog_mysql"]?.schema == "catalog")
}

@Test func datasourceFileConfigDecodesNestedMySQLAndFileMakerBlocks() throws {
    let json = """
    {
        "mysql": {"host": "db.internal", "port": 3306, "user": "u", "password": "p"},
        "filemaker": {"host": "192.0.2.1", "port": 80, "user": "fmuser", "password": "fmpass", "allowWrites": true},
        "datasources": {
            "primary_mysql": {"type": "mysql", "schema": "primary"},
            "some_filemaker_alias": {"type": "filemaker"}
        }
    }
    """
    let config = try JSONDecoder().decode(DatasourceFileConfig.self, from: Data(json.utf8))
    #expect(config.mysql?.host == "db.internal")
    #expect(config.filemaker?.host == "192.0.2.1")
    #expect(config.filemaker?.port == 80)
    #expect(config.filemaker?.allowWrites == true)
    #expect(config.datasources["primary_mysql"]?.type == .mysql)
    #expect(config.datasources["primary_mysql"]?.schema == "primary")
    #expect(config.datasources["some_filemaker_alias"]?.type == .filemaker)
    #expect(config.datasources["some_filemaker_alias"]?.schema == nil)
}

@Test func datasourceFileConfigWithOnlyFileMakerFieldsLeavesMySQLNil() throws {
    // No nested "mysql" key AND none of the legacy flat MySQL fields --
    // must not synthesize a spurious empty MySQL block.
    let json = """
    {
        "filemaker": {"host": "192.0.2.1"},
        "datasources": {"some_filemaker_alias": {"type": "filemaker"}}
    }
    """
    let config = try JSONDecoder().decode(DatasourceFileConfig.self, from: Data(json.utf8))
    #expect(config.mysql == nil)
    #expect(config.filemaker?.host == "192.0.2.1")
}

// MARK: - LassoMultiBackendInlineProvider routing

private final class InlineProviderCallRecorder: @unchecked Sendable {
    var calls: [String] = []
}

private struct RecordingExecutor: LassoDynamicQueryExecutor {
    let label: String
    let recorder: InlineProviderCallRecorder

    func execute(_ request: LassoInlineRequest) async throws -> LassoInlineFrame {
        recorder.calls.append(label)
        return LassoInlineFrame(rows: [])
    }
}

@Test func multiBackendInlineProviderRoutesByAliasToTheCorrectBackend() async throws {
    let recorder = InlineProviderCallRecorder()
    let mysqlProvider = LassoDynamicInlineProvider(executor: RecordingExecutor(label: "mysql", recorder: recorder))
    let fileMakerProvider = LassoDynamicInlineProvider(executor: RecordingExecutor(label: "filemaker", recorder: recorder))
    let provider = LassoMultiBackendInlineProvider(
        mysqlProvider: mysqlProvider,
        fileMakerProvider: fileMakerProvider,
        fileMakerAliases: ["fm_catalog"]
    )
    var context = LassoContext(inlineProvider: provider)

    _ = try await LassoRenderer().render(
        "[inline(-database='fm_catalog',-table='storefront',-findall)][/inline]",
        context: &context
    )
    _ = try await LassoRenderer().render(
        "[inline(-database='catalog_mysql',-table='skus',-findall)][/inline]",
        context: &context
    )

    #expect(recorder.calls == ["filemaker", "mysql"])
}

@Test func multiBackendInlineProviderMatchesFileMakerAliasesCaseInsensitively() async throws {
    let recorder = InlineProviderCallRecorder()
    let fileMakerProvider = LassoDynamicInlineProvider(executor: RecordingExecutor(label: "filemaker", recorder: recorder))
    let provider = LassoMultiBackendInlineProvider(
        mysqlProvider: nil,
        fileMakerProvider: fileMakerProvider,
        fileMakerAliases: ["Fm_Catalog"]
    )
    var context = LassoContext(inlineProvider: provider)

    _ = try await LassoRenderer().render(
        "[inline(-database='fm_catalog',-table='storefront',-findall)][/inline]",
        context: &context
    )

    #expect(recorder.calls == ["filemaker"])
}

@Test func multiBackendInlineProviderThrowsInlineNotConfiguredForUnroutableAliasWithNoMySQLProvider() async throws {
    let recorder = InlineProviderCallRecorder()
    let fileMakerProvider = LassoDynamicInlineProvider(executor: RecordingExecutor(label: "filemaker", recorder: recorder))
    let provider = LassoMultiBackendInlineProvider(
        mysqlProvider: nil,
        fileMakerProvider: fileMakerProvider,
        fileMakerAliases: ["fm_catalog"]
    )
    var context = LassoContext(inlineProvider: provider)

    await #expect(throws: LassoRuntimeError.inlineNotConfigured) {
        try await LassoRenderer().render(
            "[inline(-database='some_unconfigured_alias',-table='x',-findall)][/inline]",
            context: &context
        )
    }
    #expect(recorder.calls == [])
}

// MARK: - LassoAdminDelegate

// See Documentation/lasso-perfect-server.md's Admin Console section.
// `testDatasource`'s live-connectivity paths (real MySQL/FileMaker
// network calls) aren't exercised here -- covered by the manual smoke
// check against a real server instead; these tests cover the delegate's
// own pure logic (config -> DatasourceInfo mapping, status content,
// name-lookup miss path).

private func sampleServerConfig(
    datasourceMap: [String: String] = [:],
    filemakerDatasourceAliases: Set<String> = [],
    filemakerHostOverrides: [String: FileMakerHostOverride] = [:],
    sessionDriver: String = "memory",
    startupPath: URL? = nil,
    adminConsoleEnabled: Bool = false,
    renderExcludePaths: [String] = []
) -> ServerConfig {
    ServerConfig(
        siteRoot: URL(fileURLWithPath: "/tmp/sample-site"),
        port: 8181,
        lassoExtensions: ["lasso", "inc"],
        renderExcludePaths: renderExcludePaths,
        startupPath: startupPath,
        datasourceMap: datasourceMap,
        mysqlHost: "localhost",
        mysqlPort: nil,
        mysqlDatabase: "",
        mysqlUser: nil,
        mysqlPassword: nil,
        mysqlAllowWrites: false,
        mysqlAllowRawSQL: false,
        filemakerDatasourceAliases: filemakerDatasourceAliases,
        filemakerHost: filemakerDatasourceAliases.isEmpty ? nil : "192.0.2.1",
        filemakerPort: nil,
        filemakerUser: nil,
        filemakerPassword: nil,
        filemakerHostOverrides: filemakerHostOverrides,
        filemakerAllowWrites: false,
        sessionDriver: sessionDriver,
        crawlReportMode: false,
        crawlReportOutputPath: nil,
        crawlExcludePaths: [],
        crawlPathListPath: nil,
        crawlBaselinePath: nil,
        crawlOnlyFailure: nil,
        crawlRequestDelayMS: 0,
        crawlCircuitBreakerThreshold: nil,
        crawlDatasourceFailureThreshold: nil,
        imageProxyPrefix: nil,
        imageProxyTarget: nil,
        tagFormCountersEnabled: false,
        adminConsoleEnabled: adminConsoleEnabled,
        adminConsolePort: 8990,
        adminConsoleTokenPath: "/tmp/sample-admin.token"
    )
}

/// A `Task<Void, Error>` that never completes on its own — mirrors the real
/// site-server task's shape (parks until cancelled) closely enough for tests
/// that don't specifically exercise the restart-server action's cancel/drain
/// behavior. Tests that do should construct and pass their own.
private func neverCompletingTask() -> Task<Void, Error> {
    Task<Void, Error> {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(3600))
        }
    }
}

private func sampleDelegate(
    config: ServerConfig,
    fileMakerRegistry: FileMakerConnectionRegistry? = nil,
    logCapture: LogCapture? = nil,
    startTime: Date = Date(),
    siteServerTask: Task<Void, Error> = neverCompletingTask(),
    crawlTracker: CrawlRunTracker = CrawlRunTracker(),
    restartCoordinator: RestartCoordinator = RestartCoordinator()
) -> LassoAdminDelegate {
    LassoAdminDelegate(
        config: config,
        startTime: startTime,
        fileMakerRegistry: fileMakerRegistry,
        logCapture: logCapture,
        baseURL: "http://localhost:\(config.port)",
        siteServerTask: siteServerTask,
        crawlTracker: crawlTracker,
        restartCoordinator: restartCoordinator
    )
}

@Test func lassoAdminDelegateExposesServerPortAndStartTime() {
    let start = Date()
    let config = sampleServerConfig()
    let delegate = sampleDelegate(config: config, startTime: start)
    #expect(delegate.serverPort == 8181)
    #expect(delegate.serverStartTime == start)
    #expect(delegate.registeredRoutes.map(\.uri).isEmpty == false)
}

@Test func lassoAdminDelegateReturnsSortedDatasourcesAcrossBothBackends() async {
    let config = sampleServerConfig(
        datasourceMap: ["catalog_mysql": "catalog"],
        filemakerDatasourceAliases: ["fm_catalog"]
    )
    let delegate = sampleDelegate(config: config)
    let sources = await delegate.registeredDatasources()

    #expect(sources.count == 2)
    // Sorted by lowercased alias -- "catalog_mysql" before "fm_catalog".
    #expect(sources[0].alias == "catalog_mysql")
    #expect(sources[0].driver == "MySQL")
    #expect(sources[0].schema == "catalog")
    #expect(sources[0].name == "catalog_mysql")
    #expect(sources[1].alias == "fm_catalog")
    #expect(sources[1].driver == "FileMaker")
    // FileMaker's own connector model: the alias IS the schema/file name.
    #expect(sources[1].schema == "fm_catalog")
}

@Test func lassoAdminDelegateReturnsEmptyDatasourcesWhenNoneConfigured() async {
    let delegate = sampleDelegate(config: sampleServerConfig())
    let sources = await delegate.registeredDatasources()
    #expect(sources.isEmpty)
}

@Test func lassoAdminDelegateStatusSectionReflectsSiteConfig() async throws {
    let startup = URL(fileURLWithPath: "/tmp/sample-startup")
    let config = sampleServerConfig(sessionDriver: "mysql", startupPath: startup)
    let delegate = sampleDelegate(config: config)
    let sections = await delegate.additionalStatusSections()

    let siteSection = try #require(sections.first { $0.title == "Lasso Site" })
    let items = Dictionary(uniqueKeysWithValues: siteSection.items)
    #expect(items["Site root"] == "/tmp/sample-site")
    #expect(items["Startup folder"] == "/tmp/sample-startup")
    #expect(items["Session driver"] == "mysql")
    #expect(items["Render extensions"] == "inc, lasso")
}

@Test func lassoAdminDelegateStatusSectionShowsNoStartupFolderWhenUnset() async {
    let delegate = sampleDelegate(config: sampleServerConfig())
    let sections = await delegate.additionalStatusSections()
    let items = Dictionary(uniqueKeysWithValues: sections[0].items)
    #expect(items["Startup folder"] == "none")
}

@Test func lassoAdminDelegateTestDatasourceFailsCleanlyForUnknownName() async throws {
    let config = sampleServerConfig(datasourceMap: ["catalog_mysql": "catalog"])
    let delegate = sampleDelegate(config: config)
    let result = try await delegate.testDatasource(name: "not_a_real_alias")
    #expect(result.success == false)
    #expect(result.message.contains("not_a_real_alias"))
}

@Test func lassoAdminDelegateAvailableActionsAdvertisesCrawlReport() async {
    let delegate = sampleDelegate(config: sampleServerConfig())
    let actions = await delegate.availableActions()
    #expect(actions.contains { $0.name == "crawl-report" })
}

@Test func lassoAdminDelegateExecuteActionRejectsUnknownName() async throws {
    let delegate = sampleDelegate(config: sampleServerConfig())
    let result = try await delegate.executeAction("not-a-real-action")
    #expect(result.success == false)
}

@Test func lassoAdminDelegateAvailableConfigsEmptyWithNoFileMakerRegistry() async {
    let delegate = sampleDelegate(config: sampleServerConfig(filemakerDatasourceAliases: ["fm_catalog"]))
    let configs = await delegate.availableConfigs(for: "fm_catalog")
    #expect(configs.isEmpty)
}

@Test func lassoAdminDelegateSwitchDatasourceFailsCleanlyWithNoRegistry() async throws {
    let delegate = sampleDelegate(config: sampleServerConfig())
    let result = try await delegate.switchDatasource(name: "fm_catalog", to: "primary")
    #expect(result.success == false)
}

@Test func lassoAdminDelegateAvailableActionsShowsStaticDescriptionWhenIdle() async {
    let delegate = sampleDelegate(config: sampleServerConfig())
    let actions = await delegate.availableActions()
    let crawl = actions.first { $0.name == "crawl-report" }
    #expect(crawl?.description.contains("Request every discovered site page") == true)
}

@Test func lassoAdminDelegateAvailableActionsShowsLiveProgressWhileRunning() async {
    let tracker = CrawlRunTracker()
    await tracker.tryBegin()
    await tracker.progress(3, 10)
    let delegate = sampleDelegate(config: sampleServerConfig(), crawlTracker: tracker)
    let actions = await delegate.availableActions()
    let crawl = actions.first { $0.name == "crawl-report" }
    #expect(crawl?.description.contains("3/10 pages") == true)
    #expect(crawl?.description.contains("Running now") == true)
}

@Test func lassoAdminDelegateExecuteActionRejectsSecondCrawlWhileFirstIsRunning() async throws {
    let tracker = CrawlRunTracker()
    await tracker.tryBegin()
    let delegate = sampleDelegate(config: sampleServerConfig(), crawlTracker: tracker)
    let result = try await delegate.executeAction("crawl-report")
    #expect(result.success == false)
    #expect(result.message.contains("already running"))
}

// MARK: - CrawlRunTracker (crawl-report live status)

@Test func crawlRunTrackerTryBeginBlocksConcurrentStart() async {
    let tracker = CrawlRunTracker()
    let first = await tracker.tryBegin()
    let second = await tracker.tryBegin()
    #expect(first == true)
    #expect(second == false)
    #expect(await tracker.isRunning == true)
}

@Test func crawlRunTrackerProgressReflectsInStatusDescriptionWhileRunning() async {
    let tracker = CrawlRunTracker()
    await tracker.tryBegin()
    await tracker.progress(42, 100)
    let status = await tracker.statusDescription(fallback: "idle")
    #expect(status.contains("42/100 pages"))
    #expect(status.contains("Running now"))
}

@Test func crawlRunTrackerStatusDescriptionShowsStartingBeforeFirstProgressUpdate() async {
    let tracker = CrawlRunTracker()
    await tracker.tryBegin()
    let status = await tracker.statusDescription(fallback: "idle")
    #expect(status.contains("starting…"))
}

@Test func crawlRunTrackerFinishClearsRunningAndExposesSummary() async {
    let tracker = CrawlRunTracker()
    await tracker.tryBegin()
    await tracker.progress(10, 10)
    await tracker.finish(summary: "Last run: 10 page(s), 9 clean, 1 failing, 0 excluded (finished 1:00 PM).")
    #expect(await tracker.isRunning == false)
    let status = await tracker.statusDescription(fallback: "idle")
    #expect(status.contains("9 clean"))
    // A finished tracker allows starting again.
    #expect(await tracker.tryBegin() == true)
}

@Test func datasourceFailureTrackerCountsEachRecordedFailure() async {
    let tracker = DatasourceFailureTracker()
    #expect(await tracker.currentCount() == 0)
    await tracker.recordFailure()
    await tracker.recordFailure()
    #expect(await tracker.currentCount() == 2)
}

@Test func datasourceFailureTrackerResetClearsTheCount() async {
    let tracker = DatasourceFailureTracker()
    await tracker.recordFailure()
    await tracker.recordFailure()
    await tracker.reset()
    #expect(await tracker.currentCount() == 0)
    // A reset tracker still counts new failures normally.
    await tracker.recordFailure()
    #expect(await tracker.currentCount() == 1)
}

@Test func crawlRunTrackerStatusDescriptionFallsBackWhenNeverRun() async {
    let tracker = CrawlRunTracker()
    let status = await tracker.statusDescription(fallback: "idle description")
    #expect(status == "idle description")
}

// MARK: - RestartCoordinator (restart-server concurrency guard)

@Test func restartCoordinatorTryBeginBlocksConcurrentStart() async {
    let coordinator = RestartCoordinator()
    let first = await coordinator.tryBegin()
    let second = await coordinator.tryBegin()
    #expect(first == true)
    #expect(second == false)
    #expect(await coordinator.isRestarting == true)
}

@Test func restartCoordinatorResetAllowsStartingAgain() async {
    let coordinator = RestartCoordinator()
    await coordinator.tryBegin()
    await coordinator.reset()
    #expect(await coordinator.isRestarting == false)
    #expect(await coordinator.tryBegin() == true)
}

// MARK: - RestartReadiness.MarkerScanner (restart-server readiness detection)

@Test func markerScannerFindsAMarkerContainedInOneChunk() {
    var scanner = RestartReadiness.MarkerScanner()
    let found = scanner.feed("Listening: http://localhost:8281\n", markerPrefix: "Listening: http://localhost:")
    #expect(found == true)
}

@Test func markerScannerFindsAMarkerSplitAcrossTwoFeeds() {
    var scanner = RestartReadiness.MarkerScanner()
    #expect(scanner.feed("Startup folder: none\nListen", markerPrefix: "Listening: http://localhost:") == false)
    #expect(scanner.feed("ing: http://localhost:8281\n", markerPrefix: "Listening: http://localhost:") == true)
}

@Test func markerScannerIgnoresAnUnterminatedLineEvenIfItMatchesTheePrefix() {
    var scanner = RestartReadiness.MarkerScanner()
    // No trailing newline yet -- the line isn't confirmed complete, so this must
    // not report a false positive before the rest of the line (or a real newline)
    // has actually arrived.
    let found = scanner.feed("Listening: http://localhost:8281", markerPrefix: "Listening: http://localhost:")
    #expect(found == false)
}

@Test func markerScannerReturnsFalseForUnrelatedOutput() {
    var scanner = RestartReadiness.MarkerScanner()
    let found = scanner.feed("Site root: /tmp/sample-site\nSession driver: memory\n", markerPrefix: "Listening: http://localhost:")
    #expect(found == false)
}

@Test func resolveOwnExecutablePathAcceptsAnAlreadyAbsolutePath() {
    // The test executable itself is a real, executable, absolute path -- a
    // convenient stand-in that doesn't depend on any fixture file existing.
    let ownPath = ProcessInfo.processInfo.arguments[0]
    let resolved = RestartReadiness.resolveOwnExecutablePath(
        argv0: ownPath,
        currentDirectoryPath: "/nonexistent",
        pathEnvironment: nil
    )
    #expect(resolved == ownPath)
}

@Test func resolveOwnExecutablePathReturnsNilForAnAbsolutePathThatIsNotExecutable() {
    let resolved = RestartReadiness.resolveOwnExecutablePath(
        argv0: "/definitely/not/a/real/executable/path",
        currentDirectoryPath: "/tmp",
        pathEnvironment: nil
    )
    #expect(resolved == nil)
}

/// Creates a small, genuinely-executable dummy file in a fresh temp directory —
/// a controlled fixture rather than relying on the real test binary's exact
/// path shape, which isn't guaranteed to exercise every resolution branch.
private func makeExecutableFixture() throws -> (directory: URL, filename: String) {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let filename = "dummy-executable"
    let fileURL = directory.appendingPathComponent(filename)
    try Data("#!/bin/sh\n".utf8).write(to: fileURL)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fileURL.path)
    return (directory, filename)
}

@Test func resolveOwnExecutablePathResolvesARelativePathWithASlashAgainstTheCurrentDirectory() throws {
    let (directory, filename) = try makeExecutableFixture()
    defer { try? FileManager.default.removeItem(at: directory) }
    let resolved = RestartReadiness.resolveOwnExecutablePath(
        argv0: "./\(filename)",
        currentDirectoryPath: directory.path,
        pathEnvironment: nil
    )
    #expect(resolved != nil)
}

@Test func resolveOwnExecutablePathFindsABareCommandNameViaPathSearch() throws {
    let (directory, filename) = try makeExecutableFixture()
    defer { try? FileManager.default.removeItem(at: directory) }
    let resolved = RestartReadiness.resolveOwnExecutablePath(
        argv0: filename,
        currentDirectoryPath: "/tmp",
        pathEnvironment: "/usr/bin:\(directory.path):/bin"
    )
    #expect(resolved == directory.appendingPathComponent(filename).path)
}

@Test func resolveOwnExecutablePathReturnsNilWhenNothingMatchesAndThereIsNoPathToSearch() {
    let resolved = RestartReadiness.resolveOwnExecutablePath(
        argv0: "some-bare-command-name",
        currentDirectoryPath: "/tmp",
        pathEnvironment: nil
    )
    #expect(resolved == nil)
}

@Test func resolveOwnExecutablePathReturnsNilWhenBareCommandNameIsNotOnPath() {
    let resolved = RestartReadiness.resolveOwnExecutablePath(
        argv0: "some-bare-command-name",
        currentDirectoryPath: "/tmp",
        pathEnvironment: "/usr/bin:/bin"
    )
    #expect(resolved == nil)
}

// MARK: - FileMakerConnectionRegistry (live datasource switching)

@Test func fileMakerConnectionRegistryResolvesToPrimaryByDefault() async {
    let config = sampleServerConfig(filemakerDatasourceAliases: ["fm_catalog"])
    let registry = FileMakerConnectionRegistry(config: config)
    let resolved = await registry.resolve(alias: "fm_catalog")
    #expect(resolved?.host == "192.0.2.1")
}

@Test func fileMakerConnectionRegistryResolvesOverriddenAliasToItsOwnHost() async {
    let config = sampleServerConfig(
        filemakerDatasourceAliases: ["fm_catalog", "fm_catalog_backup"],
        filemakerHostOverrides: ["fm_catalog_backup": FileMakerHostOverride(host: "203.0.113.5", port: 8080)]
    )
    let registry = FileMakerConnectionRegistry(config: config)
    let primary = await registry.resolve(alias: "fm_catalog")
    #expect(primary?.host == "192.0.2.1")
    let backup = await registry.resolve(alias: "fm_catalog_backup")
    #expect(backup?.host == "203.0.113.5")
    #expect(backup?.port == 8080)
}

@Test func fileMakerConnectionRegistryResolveReturnsNilForUnknownAlias() async {
    let config = sampleServerConfig(filemakerDatasourceAliases: ["fm_catalog"])
    let registry = FileMakerConnectionRegistry(config: config)
    #expect(await registry.resolve(alias: "not_configured") == nil)
}

@Test func fileMakerConnectionRegistryAvailableProfilesListsAllKnownHostsWithActiveFlag() async {
    let config = sampleServerConfig(
        filemakerDatasourceAliases: ["fm_catalog", "fm_catalog_backup"],
        filemakerHostOverrides: ["fm_catalog_backup": FileMakerHostOverride(host: "203.0.113.5", port: 8080)]
    )
    let registry = FileMakerConnectionRegistry(config: config)
    let profiles = await registry.availableProfiles(for: "fm_catalog")
    #expect(profiles.count == 2)
    #expect(profiles.first { $0.id == "primary" }?.isActive == true)
    #expect(profiles.first { $0.id == "fm_catalog_backup" }?.isActive == false)
}

@Test func fileMakerConnectionRegistryAvailableProfilesEmptyForUnknownAlias() async {
    let config = sampleServerConfig(filemakerDatasourceAliases: ["fm_catalog"])
    let registry = FileMakerConnectionRegistry(config: config)
    #expect(await registry.availableProfiles(for: "not_configured").isEmpty)
}

@Test func fileMakerConnectionRegistrySwitchAliasTakesEffectImmediately() async {
    let config = sampleServerConfig(
        filemakerDatasourceAliases: ["fm_catalog", "fm_catalog_backup"],
        filemakerHostOverrides: ["fm_catalog_backup": FileMakerHostOverride(host: "203.0.113.5", port: 8080)]
    )
    let registry = FileMakerConnectionRegistry(config: config)
    #expect(await registry.resolve(alias: "fm_catalog")?.host == "192.0.2.1")

    let switched = await registry.switchAlias("fm_catalog", to: "fm_catalog_backup")
    #expect(switched?.host == "203.0.113.5")
    #expect(await registry.resolve(alias: "fm_catalog")?.host == "203.0.113.5")

    // The profile list now reflects the new active profile too.
    let profiles = await registry.availableProfiles(for: "fm_catalog")
    #expect(profiles.first { $0.id == "fm_catalog_backup" }?.isActive == true)
    #expect(profiles.first { $0.id == "primary" }?.isActive == false)
}

@Test func fileMakerConnectionRegistrySwitchAliasFailsForUnknownAliasOrProfile() async {
    let config = sampleServerConfig(filemakerDatasourceAliases: ["fm_catalog"])
    let registry = FileMakerConnectionRegistry(config: config)
    #expect(await registry.switchAlias("not_configured", to: "primary") == nil)
    #expect(await registry.switchAlias("fm_catalog", to: "not_a_real_profile") == nil)
}
