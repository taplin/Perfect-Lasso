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
        parameters[name.lowercased()] ?? .void
    }

    func header(named name: String) -> LassoValue {
        name.lowercased() == "host" ? .string("example.test") : .void
    }

    func cookie(named name: String) -> LassoValue {
        name.lowercased() == "sid" ? .string("abc123") : .void
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

// MARK: - Custom tags: definition, parameter defaults, return, recursion depth

var tagContext = LassoContext()
let greetSource = """
<?lassoscript
define greet_tag(#name, #greeting='Hello') => {
    return #greeting + ', ' + #name + '!'
}
?>
[greet_tag('Ada')] / [greet_tag('Bo', 'Hi')]
"""
let greetOutput = try LassoRenderer().render(greetSource, context: &tagContext)
precondition(greetOutput.trimmingCharacters(in: .whitespacesAndNewlines) == "Hello, Ada! / Hi, Bo!", "Custom tag define/call failed: \(greetOutput)")

let tagExistsOutput = try LassoRenderer().render(
    "[lasso_tagexists('string')]|[tag_exists('greet_tag')]|[tag_exists('missing_tag')]",
    context: &tagContext
)
precondition(
    tagExistsOutput == "true|true|false",
    "tag_exists/lasso_tagexists failed: \(tagExistsOutput)"
)

var typeContext = LassoContext()
let typeOutput = try LassoRenderer().render(
    """
    <?lassoscript
    define Widget => type {
        data public name::string
        public onCreate(name::string) => {
            self->name = #name
        }
        public greet(prefix='Hello') => {
            return #prefix + ', ' + self->name
        }
        public classify(value::integer) => {
            return 'integer'
        }
        public classify(value) => {
            return 'any'
        }
    }
    local(widget::Widget = Widget('Ada'))
    ?>
    [#widget->name]|[#widget->greet()]|[#widget->greet('Hi')]|[#widget->classify(7)]|[#widget->classify('seven')]
    """,
    context: &typeContext
).trimmingCharacters(in: .whitespacesAndNewlines)
precondition(
    typeOutput == "Ada|Hello, Ada|Hi, Ada|integer|any",
    "Type definition/object dispatch failed: \(typeOutput)"
)

let isolationSource = """
<?lassoscript
define increment_tag(#value) => {
    local(result = #value + 1)
    return #result
}
?>
[local(result = 100)][increment_tag(5)] / [#result]
"""
let isolationOutput = try LassoRenderer().render(isolationSource, context: &tagContext)
precondition(
    isolationOutput.trimmingCharacters(in: .whitespacesAndNewlines) == "6 / 100",
    "Custom tag local-scope isolation failed: \(isolationOutput)"
)

let shortCircuitSource = """
<?lassoscript
define short_circuit_tag(#flag) => {
    if(#flag)
        return 'early'
    /if
    return 'late'
}
?>
[short_circuit_tag(true)] / [short_circuit_tag(false)]
"""
let shortCircuitOutput = try LassoRenderer().render(shortCircuitSource, context: &tagContext)
precondition(
    shortCircuitOutput.trimmingCharacters(in: .whitespacesAndNewlines) == "early / late",
    "Custom tag return short-circuiting failed: \(shortCircuitOutput)"
)

let recursionSource = """
<?lassoscript
define recurse_tag(#n) => {
    if(#n <= 0)
        return 0
    /if
    return 1 + recurse_tag(#n - 1)
}
?>
[recurse_tag(3)]
"""
let recursionOutput = try LassoRenderer().render(recursionSource, context: &tagContext)
precondition(recursionOutput.trimmingCharacters(in: .whitespacesAndNewlines) == "3", "Custom tag recursion failed: \(recursionOutput)")

do {
    var deepContext = LassoContext()
    _ = try LassoRenderer().render(
        """
        <?lassoscript
        define deep_recurse_tag(#n) => {
            if(#n <= 0)
                return 0
            /if
            return 1 + deep_recurse_tag(#n - 1)
        }
        ?>
        [deep_recurse_tag(30)]
        """,
        context: &deepContext
    )
    fatalError("Expected tag call depth exceeded for 30-deep recursion")
} catch LassoRuntimeError.tagCallDepthExceeded {
    // Expected: the recursion-depth guard tripped before a stack overflow.
} catch {
    fatalError("Unexpected error for deep custom tag recursion: \(error)")
}

// MARK: - library(): loads and caches across independently-constructed contexts

final class CountingLibraryLoader: LassoIncludeLoader, @unchecked Sendable {
    private(set) var loadCount = 0
    private let librarySource: String

    init(librarySource: String) {
        self.librarySource = librarySource
    }

    func loadInclude(path: String, from includingPath: String?) throws -> String {
        loadCount += 1
        return librarySource
    }
}

let countingLoader = CountingLibraryLoader(librarySource: """
<?lassoscript
define shared_tag(#x) => {
    return #x * 2
}
?>
""")
let sharedTagRegistry = LassoTagRegistry()

func renderAgainstSharedRegistry(_ source: String) throws -> String {
    var requestContext = LassoContext(includeLoader: countingLoader, tagRegistry: sharedTagRegistry)
    return try LassoRenderer().render(source, context: &requestContext)
}

let firstRequestOutput = try renderAgainstSharedRegistry(
    "<?lassoscript library('/shared.lasso') ?>[shared_tag(21)]"
)
let secondRequestOutput = try renderAgainstSharedRegistry(
    "<?lassoscript library('/shared.lasso') ?>[shared_tag(10)]"
)
precondition(firstRequestOutput == "42", "Library-defined tag call failed: \(firstRequestOutput)")
precondition(secondRequestOutput == "20", "Library-defined tag call failed on second request: \(secondRequestOutput)")
precondition(
    countingLoader.loadCount == 1,
    "Expected library to load exactly once across two independent contexts sharing one registry, got \(countingLoader.loadCount)"
)

// MARK: - include(): always re-read and re-rendered (it can produce output
// on every use, unlike a library), but re-parsing is skipped whenever the
// freshly read source matches what was cached last time.

final class MutableIncludeLoader: LassoIncludeLoader, @unchecked Sendable {
    private(set) var loadCount = 0
    var content: String

    init(content: String) {
        self.content = content
    }

    func loadInclude(path: String, from includingPath: String?) throws -> String {
        loadCount += 1
        return content
    }
}

let includeRegistry = LassoTagRegistry()
let mutableLoader = MutableIncludeLoader(content: "v1: [local(x = 1)][#x]")

func renderAgainstIncludeRegistry(_ source: String) throws -> String {
    var requestContext = LassoContext(includeLoader: mutableLoader, tagRegistry: includeRegistry)
    return try LassoRenderer().render(source, context: &requestContext)
}

let includeFirstOutput = try renderAgainstIncludeRegistry("[include('shared.lasso')]")
let includeSecondOutput = try renderAgainstIncludeRegistry("[include('shared.lasso')]")
precondition(includeFirstOutput == "v1: 1", "Include rendering failed: \(includeFirstOutput)")
precondition(includeSecondOutput == "v1: 1", "Include rendering failed on second use: \(includeSecondOutput)")
precondition(
    mutableLoader.loadCount == 2,
    "Expected include to be re-read (I/O) on every use, got \(mutableLoader.loadCount) reads"
)

// Output alone can't distinguish a cache hit from a fresh reparse (both
// produce identical text), so verify the cache directly: a hit on identical
// source, a miss on changed source.
let cacheProbeRegistry = LassoTagRegistry()
precondition(
    cacheProbeRegistry.cachedInclude(forKey: "probe", matchingSource: "abc") == nil,
    "Expected a cache miss before anything has been cached"
)
let probeDocument = LassoParser().parse("abc")
cacheProbeRegistry.cacheInclude(forKey: "probe", source: "abc", document: probeDocument)
precondition(
    cacheProbeRegistry.cachedInclude(forKey: "probe", matchingSource: "abc") == probeDocument,
    "Expected a cache hit for identical source"
)
precondition(
    cacheProbeRegistry.cachedInclude(forKey: "probe", matchingSource: "changed") == nil,
    "Expected a cache miss once the source changes"
)

// Changing the included file's content between uses must not serve stale
// output — caching is content-based, not "first result wins forever".
mutableLoader.content = "v2: [local(x = 2)][#x]"
let includeThirdOutput = try renderAgainstIncludeRegistry("[include('shared.lasso')]")
precondition(
    includeThirdOutput == "v2: 2",
    "Stale include content served after a real change: \(includeThirdOutput)"
)

// MARK: - <?lasso ?> / <?= ?> block support (arrow-brace and slash-closed)

var lassoBlockContext = LassoContext()
let braceIfSource = """
<?lasso
var(triggered::boolean = false)
if(!$triggered) => {
    $triggered = true
    $inside = 'yes'
}
var(after::string = 'done')
?>
[$triggered]/[$inside]/[$after]
"""
let braceIfOutput = try LassoRenderer().render(braceIfSource, context: &lassoBlockContext)
precondition(
    braceIfOutput.trimmingCharacters(in: .whitespacesAndNewlines) == "true/yes/done",
    "Brace-style <?lasso ?> if failed, or content after '}' was swallowed into its body: \(braceIfOutput)"
)

let braceIfElseTrueSource = """
<?lasso
if(true) => {
    $branch = 'if'
} else => {
    $branch = 'else'
}
?>
[$branch]
"""
let braceIfElseTrueOutput = try LassoRenderer().render(braceIfElseTrueSource, context: &lassoBlockContext)
precondition(
    braceIfElseTrueOutput.trimmingCharacters(in: .whitespacesAndNewlines) == "if",
    "Brace-style if/else (true branch) failed: \(braceIfElseTrueOutput)"
)

let braceIfElseFalseSource = """
<?lasso
if(false) => {
    $branch = 'if'
} else => {
    $branch = 'else'
}
?>
[$branch]
"""
let braceIfElseFalseOutput = try LassoRenderer().render(braceIfElseFalseSource, context: &lassoBlockContext)
precondition(
    braceIfElseFalseOutput.trimmingCharacters(in: .whitespacesAndNewlines) == "else",
    "Brace-style if/else (false branch) failed: \(braceIfElseFalseOutput)"
)

let mixedNestingSource = """
<?lasso
if(true)
    if(true) => {
        $nested = 'yes'
    }
/if
?>
[$nested]
"""
let mixedNestingOutput = try LassoRenderer().render(mixedNestingSource, context: &lassoBlockContext)
precondition(
    mixedNestingOutput.trimmingCharacters(in: .whitespacesAndNewlines) == "yes",
    "Brace-style if nested inside a slash-style if failed: \(mixedNestingOutput)"
)

// Direct regression for the originally reported real-corpus symptom: a
// bare `if(...) => { ... }` inside plain <?lasso ?> (not <?lassoscript ?>)
// used to parse "if" as a call to an undefined function named "if".
let realWorldShapeSource = """
<?lasso
if(!$demo_setup_done) => {
    $demo_setup_done = true
}
?>
[$demo_setup_done]
"""
let realWorldShapeOutput = try LassoRenderer().render(realWorldShapeSource, context: &lassoBlockContext)
precondition(
    realWorldShapeOutput.trimmingCharacters(in: .whitespacesAndNewlines) == "true",
    "Real-corpus if(...) => {...} shape under <?lasso ?> failed: \(realWorldShapeOutput)"
)

// MARK: - ScriptBodyParser diagnostics

let unterminatedBrace = LassoParser().parse("<?lasso if(true) => { $x = 1 ?>")
precondition(
    !unterminatedBrace.diagnostics.isEmpty,
    "Expected a diagnostic for an unterminated brace body"
)

let strayBrace = LassoParser().parse("<?lasso } ?>")
precondition(
    strayBrace.diagnostics.contains { $0.message == "Unexpected closing brace" },
    "Expected an 'Unexpected closing brace' diagnostic"
)

let malformedDefine = LassoParser().parse("<?lassoscript define ?>")
precondition(
    malformedDefine.diagnostics.contains { $0.message.hasPrefix("Malformed 'define'") },
    "Expected a malformed-define diagnostic"
)

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
