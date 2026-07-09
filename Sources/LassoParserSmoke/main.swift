import Foundation
import LassoParser
import LassoPerfectCRUD
import PerfectCRUD

let environment = ProcessInfo.processInfo.environment

let fixtureRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appendingPathComponent("Tests/LassoParserTests/Fixtures")
let fixtures = try FileManager.default.contentsOfDirectory(
    at: fixtureRoot,
    includingPropertiesForKeys: nil
).filter { !$0.hasDirectoryPath }

precondition(fixtures.count == 16, "Expected 16 parser fixtures")
for fixture in fixtures {
    let source = try String(contentsOf: fixture, encoding: .utf8)
    let document = LassoParser().parse(source)
    precondition(document.diagnostics.isEmpty, "Diagnostics in \(fixture.lastPathComponent)")
    precondition(!document.nodes.isEmpty, "No nodes in \(fixture.lastPathComponent)")
}

let legacy = LassoParser().parse("[include:'header.htm']")
let modern = LassoParser().parse("[include('header.htm')]")
guard case let .expression(legacyExpression, .lasso8, _, _) = legacy.nodes.first,
      case let .expression(modernExpression, .lasso9, _, _) = modern.nodes.first else {
    fatalError("Expected normalized expression nodes")
}
precondition(legacyExpression == modernExpression, "Call syntaxes did not normalize")

let blocks = LassoParser().parse("[if:$active]Yes[else]No[/if]")
precondition(blocks.nodes.count == 1, "Legacy block structure was not nested")
guard case let .block(name, _, body, alternate, _, _) = blocks.nodes[0] else {
    fatalError("Expected a nested block")
}
precondition(name.lowercased() == "if" && body.count == 1 && alternate?.count == 1)

let disabled = LassoParser().parse("[no_square_brackets]<script>const values = [1, 2, 3];</script>")
precondition(disabled.nodes.count == 2, "Square bracket disabling failed")

let renderFixtureRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appendingPathComponent("Tests/LassoParserTests/RenderFixtures")
let renderInputs = try FileManager.default.contentsOfDirectory(
    at: renderFixtureRoot,
    includingPropertiesForKeys: nil
).filter { $0.pathExtension == "lasso" }
for input in renderInputs {
    let source = try String(contentsOf: input, encoding: .utf8)
    let expected = try String(
        contentsOf: input.deletingPathExtension().appendingPathExtension("html"),
        encoding: .utf8
    )
    var context = LassoContext(globals: [
        "name": .string("Ada"),
        "unsafe": .string("<strong>unsafe & raw</strong>"),
    ])
    let actual = try LassoRenderer().render(source, context: &context)
    precondition(actual == expected, "Golden mismatch in \(input.lastPathComponent)")
}

var natives = LassoNativeRegistry()
natives.register("greet") { arguments, _ in
    .string("Hello, \(arguments.first?.value.outputString ?? "friend")")
}
var nativeContext = LassoContext(natives: natives)
let nativeOutput = try LassoRenderer().render("[greet('Ada')]", context: &nativeContext)
precondition(nativeOutput == "Hello, Ada", "Native function registration failed")

struct SmokeIncludeLoader: LassoIncludeLoader {
    func loadInclude(path: String, from includingPath: String?) throws -> String {
        precondition(path == "partials/header.lasso")
        return "<h1>[string($title)]</h1>"
    }
}

struct SmokeRequestProvider: LassoRequestProvider {
    let parameters: [String: LassoValue] = ["term": .string("clogs")]

    func parameter(named name: String) -> LassoValue {
        parameters[name.lowercased()] ?? .null
    }

    func header(named name: String) -> LassoValue {
        name.lowercased() == "host" ? .string("example.test") : .null
    }

    func cookie(named name: String) -> LassoValue {
        name.lowercased() == "sid" ? .string("abc123") : .null
    }
}

final class SmokeSessionProvider: LassoSessionProvider, @unchecked Sendable {
    private var values: [String: LassoValue] = [:]

    func value(for name: String) -> LassoValue {
        values[name.lowercased()] ?? .null
    }

    func set(_ value: LassoValue, for name: String) throws {
        values[name.lowercased()] = value
    }
}

var backendContext = LassoContext(
    globals: ["title": .string("Catalog")],
    includeLoader: SmokeIncludeLoader(),
    requestProvider: SmokeRequestProvider(),
    sessionProvider: SmokeSessionProvider(),
    inlineProvider: LassoInMemoryInlineProvider(tables: [
        "items": [
            LassoDataRow(["name": .string("Alpha"), "qty": .integer(2), "active": .string("yes")]),
            LassoDataRow(["name": .string("Beta"), "qty": .integer(3), "active": .string("yes")]),
            LassoDataRow(["name": .string("Gamma"), "qty": .integer(1), "active": .string("no")]),
        ],
    ])
)
let includeOutput = try LassoRenderer().render("[include:'partials/header.lasso']", context: &backendContext)
precondition(includeOutput == "<h1>Catalog</h1>", "Include rendering failed")

let requestOutput = try LassoRenderer().render(
    "[web_request->param('term')]|[web_request->header('host')]|[cookie:'sid']",
    context: &backendContext
)
precondition(requestOutput == "clogs|example.test|abc123", "Request provider rendering failed")

let sessionOutput = try LassoRenderer().render(
    "[session_addvar:'cart','open'][session:'cart']",
    context: &backendContext
)
precondition(sessionOutput == "open", "Session provider rendering failed")

let inlineSource = "[inline:-search,-database='demo',-table='items',-op='eq',-active='yes',-sortfield='name']" +
    "[records][field:'name']:[field:'qty'];[/records]([found_count])[/inline]"
let inlineOutput = try LassoRenderer().render(inlineSource, context: &backendContext)
precondition(inlineOutput == "Alpha:2;Beta:3;(2)", "Inline records rendering failed")

struct CorpusIncludeLoader: LassoIncludeLoader {
    let sources: [String: String] = [
        "billboard.txt": "[local(pid = '247')]<a href=\"[$http]/store.lasso?pid=[#pid]\">Billboard</a>",
        "keywords/tops.lasso": "Demo-Category-Tops-Womens Closeouts",
    ]

    func loadInclude(path: String, from includingPath: String?) throws -> String {
        guard let source = sources[path] else {
            throw NSError(
                domain: "CorpusIncludeLoader",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Missing smoke include: \(path)"]
            )
        }
        return source
    }
}

var corpusContext = LassoContext(
    globals: [
        "http": .string("https://demo.example"),
        "url_prefix": .string(""),
        "response_filepath": .string("/store.lasso"),
        "product_subset": .string("DEMO"),
    ],
    includeLoader: CorpusIncludeLoader(),
    inlineProvider: LassoInMemoryInlineProvider(tables: [
        "skus": [
            LassoDataRow([
                "store_id": .string("DEMO"),
                "featured": .string("seasonal_sale_top"),
                "mfr_style_no": .string("247"),
                "color": .string("Black"),
            ]),
            LassoDataRow([
                "store_id": .string("DEMO"),
                "featured": .string("seasonal_sale_pant"),
                "mfr_style_no": .string("701"),
                "color": .string("Navy"),
            ]),
        ],
    ])
)
let corpusBillboard = try LassoRenderer().render("[include('billboard.txt')]", context: &corpusContext)
precondition(
    corpusBillboard == "<a href=\"https://demo.example/store.lasso?pid=247\">Billboard</a>",
    "Corpus billboard include failed"
)
let corpusCategory = try LassoRenderer().render(
    "<a href=\"[$URL_Prefix][response_filepath]?cid=tops&keywords=[include('keywords/tops.lasso')]\">Tops</a>",
    context: &corpusContext
)
precondition(
    corpusCategory == "<a href=\"/store.lasso?cid=tops&keywords=Demo-Category-Tops-Womens Closeouts\">Tops</a>",
    "Corpus category include failed"
)
let corpusCloseout = """
[inline(-database='catalog_mysql',-table='skus',-op='cn','store_id'=$product_subset,
    -op='cn','featured'='seasonal_sale',-ReturnField='mfr_style_no',-ReturnField='color',-search)]
[records][field('mfr_style_no')]:[field('color')];[/records][/inline]
"""
let corpusCloseoutOutput = try LassoRenderer().render(corpusCloseout, context: &corpusContext)
precondition(
    corpusCloseoutOutput.replacingOccurrences(of: "\n", with: "") == "247:Black;701:Navy;",
    "Corpus closeout carousel query failed: \(corpusCloseoutOutput)"
)

let perfectCRUDExecutor = PerfectCRUDLassoExecutor { datasource, query in
    precondition(datasource == "catalog")
    precondition(query.table == "skus")
    precondition(query.predicates.count == 2)
    return DynamicResult(
        rows: [
            DynamicRow(["mfr_style_no": .string("247"), "color": .string("Black")]),
            DynamicRow(["mfr_style_no": .string("701"), "color": .string("Navy")]),
        ],
        statement: "SELECT ..."
    )
}
var perfectCRUDContext = LassoContext(
    globals: ["product_subset": .string("DEMO")],
    inlineProvider: LassoDynamicInlineProvider(
        executor: perfectCRUDExecutor,
        datasourceAliases: ["catalog_mysql": "catalog"]
    )
)
let perfectCRUDOutput = try LassoRenderer().render(corpusCloseout, context: &perfectCRUDContext)
precondition(
    perfectCRUDOutput.replacingOccurrences(of: "\n", with: "") == "247:Black;701:Navy;",
    "PerfectCRUD Lasso executor parity failed"
)

let corpusFixtureRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appendingPathComponent("Tests/LassoParserTests/CorpusFixtures")
let corpusLoader = try LassoFileSystemIncludeLoader(root: corpusFixtureRoot)
let corpusFixtureInputs = try FileManager.default.contentsOfDirectory(
    at: corpusFixtureRoot,
    includingPropertiesForKeys: nil
).filter { $0.pathExtension == "lasso" }
precondition(corpusFixtureInputs.count == 6, "Expected six corpus fixtures")
for input in corpusFixtureInputs {
    let source = try String(contentsOf: input, encoding: .utf8)
    let expected = try String(
        contentsOf: input.deletingPathExtension().appendingPathExtension("html"),
        encoding: .utf8
    )
    var context = LassoContext(
        globals: [
            "http": .string("https://demo.example"),
            "url_prefix": .string(""),
            "response_filepath": .string("/store.lasso"),
            "product_subset": .string("DEMO"),
        ],
        includeLoader: corpusLoader,
        includePath: input.lastPathComponent,
        inlineProvider: LassoInMemoryInlineProvider(tables: [
            "skus": [
                LassoDataRow(["store_id": .string("DEMO"), "featured": .string("seasonal_sale_top"), "mfr_style_no": .string("247"), "color": .string("Black")]),
                LassoDataRow(["store_id": .string("DEMO"), "featured": .string("seasonal_sale_pant"), "mfr_style_no": .string("701"), "color": .string("Navy")]),
                LassoDataRow(["store_id": .string("DEMO"), "featured": .string("Yes"), "mfr_style_no": .string("316"), "color": .string("Wine")]),
                LassoDataRow(["store_id": .string("DEMO"), "featured": .string("Yes"), "mfr_style_no": .string("731"), "color": .string("Navy")]),
            ],
            "products": [
                LassoDataRow(["mfr_style_no": .string("316"), "short_description": .string("Stretch V-neck Top")]),
                LassoDataRow(["mfr_style_no": .string("731"), "short_description": .string("Cargo Jogger")]),
            ],
        ])
    )
    let output = try LassoRenderer().render(source, context: &context)
    precondition(
        output.trimmingCharacters(in: .newlines) == expected.trimmingCharacters(in: .newlines),
        "Corpus fixture mismatch in \(input.lastPathComponent): \(output)"
    )
}

// Opt-in local smoke check against a real page from a developer's own site
// checkout. Unset by default so no site-specific path or content ever lives
// in source; set both env vars locally to exercise it against a real corpus.
if let realPageRelativePath = environment["LASSO_SMOKE_REAL_PAGE_PATH"],
   let realSiteRootPath = environment["LASSO_SMOKE_REAL_SITE_ROOT"] {
    let siteRoot = URL(fileURLWithPath: realSiteRootPath)
    let realPagePath = siteRoot.appendingPathComponent(realPageRelativePath).path
    if FileManager.default.fileExists(atPath: realPagePath) {
        let realPageLoader = try LassoFileSystemIncludeLoader(root: siteRoot)
        let realPageSource = try String(contentsOfFile: realPagePath, encoding: .utf8)
        var realPageContext = LassoContext(
            globals: [
                "http": .string("https://demo.example"),
                "url_prefix": .string(""),
                "response_filepath": .string("/store.lasso"),
                "product_subset": .string("DEMO"),
                "store_abbrev": .string("demo"),
                "page": .string("demo/demo.home"),
                "cust_id": .string("smoke"),
                "start_msec": .integer(0),
            ],
            includeLoader: realPageLoader,
            includePath: realPageRelativePath,
            inlineProvider: LassoInMemoryInlineProvider(tables: [:])
        )
        let realPageOutput = try LassoRenderer().render(realPageSource, context: &realPageContext)
        precondition(!realPageOutput.isEmpty, "Real page smoke render produced no output")
        print("Rendered real-page smoke check against \(realPageRelativePath) (\(realPageOutput.count) bytes).")
    }
}

let scriptInline = """
<?lassoscript
inline(
    -database = 'catalog_mysql',
    -table = 'skus',
    -op = 'cn',
    'store_id' = $product_subset,
    -ReturnField = 'catalog_sku',
    -search)
    return json_serialize(records_map)
/inline
?>
"""
let scriptDocument = LassoParser().parse(scriptInline)
precondition(scriptDocument.diagnostics.isEmpty, "Script inline produced diagnostics")
guard case let .block(scriptBlockName, scriptArguments, scriptBody, _, _, _) = scriptDocument.nodes.first else {
    fatalError("Expected script inline to become a block")
}
precondition(scriptBlockName.lowercased() == "inline", "Expected inline script block")
precondition(scriptArguments.count == 6, "Expected script inline arguments")
precondition(scriptBody.count == 1, "Expected return statement inside script inline")

struct ScriptInlineProvider: LassoInlineProvider {
    func executeInline(arguments: [EvaluatedArgument], context: LassoContext) throws -> LassoInlineFrame {
        let request = LassoInlineRequest(arguments: arguments)
        precondition(request.database == "catalog_mysql", "Script inline database did not normalize")
        precondition(request.table == "skus", "Script inline table did not normalize")
        precondition(request.criteria.first?.field == "store_id", "String-key criterion did not normalize")
        return LassoInlineFrame(rows: [
            LassoDataRow(["catalog_sku": .string("SKU-1"), "preview": .string("one.jpg")]),
        ])
    }
}
var scriptContext = LassoContext(
    globals: ["product_subset": .string("demo-product-line")],
    inlineProvider: ScriptInlineProvider()
)
let scriptRenderSource = """
<?lassoscript
inline(
    -database = 'catalog_mysql',
    -table = 'skus',
    -op = 'cn',
    'store_id' = $product_subset,
    -ReturnField = 'catalog_sku',
    -search)
/inline
?>
"""
_ = try LassoRenderer().render(scriptRenderSource, context: &scriptContext)

let scriptJSONSource = """
<?lassoscript
inline(
    -database = 'catalog_mysql',
    -table = 'skus',
    -op = 'cn',
    'store_id' = $product_subset,
    -ReturnField = 'catalog_sku',
    -ReturnField = 'preview',
    -search)
    log_critical('found ' + found_count + ' featured records')
    return json_serialize(records_map)
/inline
?>
"""
let scriptJSONOutput = try LassoRenderer().render(scriptJSONSource, context: &scriptContext)
precondition(
    scriptJSONOutput == "[{\"preview\":\"one.jpg\",\"catalog_sku\":\"SKU-1\"}]" ||
        scriptJSONOutput == "[{\"catalog_sku\":\"SKU-1\",\"preview\":\"one.jpg\"}]",
    "Script inline JSON rendering failed: \(scriptJSONOutput)"
)

// Opt-in local smoke check against a real script-mode page. Unset by default;
// set LASSO_SMOKE_REAL_API_PAGE_PATH locally to an absolute path to exercise it.
if let apiPath = environment["LASSO_SMOKE_REAL_API_PAGE_PATH"],
   FileManager.default.fileExists(atPath: apiPath) {
    let apiSource = try String(contentsOfFile: apiPath, encoding: .utf8)
    let apiDocument = LassoParser().parse(apiSource)
    precondition(apiDocument.diagnostics.isEmpty, "Real API page produced parser diagnostics")
    let inlineCount = countBlocks(named: "inline", in: apiDocument.nodes)
    print("Real API page smoke check parsed \(inlineCount) inline block(s) from \(apiPath).")
}

let malformed = LassoParser().parse("[if:true]Unclosed")
precondition(!malformed.diagnostics.isEmpty, "Expected an unclosed block diagnostic")

print(
    "Parsed \(fixtures.count) fixtures and rendered \(renderInputs.count) golden cases plus " +
        "\(corpusFixtureInputs.count) corpus cases."
)

func countBlocks(named target: String, in nodes: [LassoNode]) -> Int {
    nodes.reduce(0) { count, node in
        guard case let .block(name, _, body, alternate, _, _) = node else { return count }
        return count +
            (name.caseInsensitiveCompare(target) == .orderedSame ? 1 : 0) +
            countBlocks(named: target, in: body) +
            countBlocks(named: target, in: alternate ?? [])
    }
}
