import LassoParser

/// Routes each `[inline(...)]` request to the right backend-specific
/// `LassoDynamicInlineProvider` by which alias set its `-database=` value
/// belongs to, rather than trying to make one executor type serve both
/// MySQL and FileMaker datasources. A deployment configures at most one
/// MySQL connection and one FileMaker Server connection (see
/// `DatasourceFileConfig`), each wrapped in its own `LassoDynamicInlineProvider`.
///
/// FileMaker aliases are matched first and explicitly (`fileMakerAliases`,
/// lowercased at init); everything else — including a genuinely
/// unconfigured alias — falls through to `mysqlProvider`, matching
/// `LassoDynamicInlineProvider`'s own existing behavior of passing an
/// unrecognized alias through unmapped to its executor, which is where the
/// "is this datasource actually configured" rejection already lives
/// (`LassoSiteServerError.unknownDatasource`). If neither backend is
/// configured, `LassoSiteServer` doesn't construct this provider at all
/// (`inlineProvider` stays `nil`, `[inline(...)]` throws
/// `LassoRuntimeError.inlineNotConfigured` at the renderer level) — but a
/// FileMaker-only deployment with no MySQL still needs this to raise the
/// same error for a stray MySQL-shaped alias, which `mysqlProvider == nil`
/// below handles.
struct LassoMultiBackendInlineProvider: LassoInlineProvider {
    let mysqlProvider: LassoDynamicInlineProvider?
    let fileMakerProvider: LassoDynamicInlineProvider?
    private let fileMakerAliases: Set<String>

    init(
        mysqlProvider: LassoDynamicInlineProvider?,
        fileMakerProvider: LassoDynamicInlineProvider?,
        fileMakerAliases: Set<String>
    ) {
        self.mysqlProvider = mysqlProvider
        self.fileMakerProvider = fileMakerProvider
        self.fileMakerAliases = Set(fileMakerAliases.map { $0.lowercased() })
    }

    func executeInline(arguments: [EvaluatedArgument], context: LassoContext) throws -> LassoInlineFrame {
        let request = LassoInlineRequest(arguments: arguments)
        if let database = request.database, fileMakerAliases.contains(database.lowercased()),
           let fileMakerProvider {
            return try fileMakerProvider.executeInline(arguments: arguments, context: context)
        }
        guard let mysqlProvider else {
            throw LassoRuntimeError.inlineNotConfigured
        }
        return try mysqlProvider.executeInline(arguments: arguments, context: context)
    }
}
