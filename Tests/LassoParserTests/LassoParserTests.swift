import Foundation
import Testing
@testable import LassoParser
import LassoPerfectCRUD
import PerfectCRUD

@Test func allFixturesParseWithoutDiagnostics() throws {
    let fixtureURL = try #require(Bundle.module.resourceURL?.appendingPathComponent("Fixtures"))
    let files = try FileManager.default.contentsOfDirectory(
        at: fixtureURL,
        includingPropertiesForKeys: nil
    ).filter { !$0.hasDirectoryPath }

    #expect(files.count == 16)
    for file in files {
        let source = try String(contentsOf: file, encoding: .utf8)
        let document = LassoParser().parse(source)
        #expect(document.diagnostics.isEmpty, "Unexpected diagnostics in \(file.lastPathComponent)")
        #expect(!document.nodes.isEmpty)
    }
}

@Test func normalizesLegacyAndModernCalls() {
    let legacy = LassoParser().parse("[include:'header.htm']")
    let modern = LassoParser().parse("[include('header.htm')]")

    guard case let .expression(legacyExpression, .lasso8, _, _) = legacy.nodes.first,
          case let .expression(modernExpression, .lasso9, _, _) = modern.nodes.first else {
        Issue.record("Expected expression nodes")
        return
    }
    #expect(legacyExpression == modernExpression)
}

@Test func preservesLegacyBlockTags() {
    let document = LassoParser().parse("[if:$active]Yes[else]No[/if]")
    #expect(document.nodes.count == 1)
    guard case let .block(name, arguments, body, alternate, dialect, _) = document.nodes[0] else {
        Issue.record("Expected nested if block")
        return
    }
    #expect(name.lowercased() == "if")
    #expect(arguments.count == 1)
    #expect(body.count == 1)
    #expect(alternate?.count == 1)
    #expect(dialect == .lasso8)
}

@Test func noSquareBracketsLeavesRemainingTextUntouched() {
    let source = "[no_square_brackets]<script>const values = [1, 2, 3];</script>"
    let document = LassoParser().parse(source)
    #expect(document.nodes.count == 2)
    guard case let .text(text, _) = document.nodes[1] else {
        Issue.record("Expected trailing text")
        return
    }
    #expect(text.contains("[1, 2, 3]"))
}

@Test func squareBracketScanningSkipsCommentsWhenFindingTheClosingBracket() throws {
    // Real Lasso lets a whole `[ ... ]` span hold a full `define ... =>
    // { ... }` custom tag with a leading `//lasso` comment as a human hint
    // that the bracket contains Lasso code — a real idiom found in
    // startup-folder tag definitions downloaded from
    // lassosoft.com/tagswap. Two things had to be fixed together for this
    // to actually work, not just avoid throwing:
    //  1. TemplateScanner.scanSquare()'s naive quote-tracking had no
    //     comment awareness at all: an apostrophe or a `]` inside a `//`
    //     or `/* */` comment (a possessive name, a `[tag(...)]` usage
    //     example in a file-header comment) was indistinguishable from a
    //     real string delimiter or the bracket's own closing `]`.
    //  2. emitCode's legacy-closing-tag check (`body.hasPrefix("/")`)
    //     misfired on the leading `//` comment marker itself, swallowing
    //     the entire body — including the real `define` — as a bogus
    //     closing tag. The bracket "loaded" with no error, but the tag it
    //     defined was silently never registered.
    var context = LassoContext()
    let output = try LassoRenderer().render(
        """
        [//lasso
        /* Header comment mentioning someone's tag usage: [example_tag(1)]
           and a line with 'a quoted word' inside it too. */
        define greetFromBracket(name = void) => {
            // a plain line comment with a bracket example: [also_not_real]
            return('hi ' + #name)
        }
        ]
        [greetFromBracket(-name='there')]
        """,
        context: &context
    ).trimmingCharacters(in: .whitespacesAndNewlines)
    #expect(output == "hi there")
}

@Test func noProcessPassesThroughRawContentWithoutScanningItAsLasso() throws {
    // Real Lasso's documented escape hatch for embedding non-Lasso content
    // (almost always Dreamweaver-era JavaScript) inside a template — used
    // throughout the real corpus. Found live-verifying a real page whose
    // template embedded unwrapped JS containing `[j++]` (ordinary array
    // indexing plus a post-increment), which crashed: `++` isn't a valid
    // Lasso operator, so the bracket's content failed to parse as an
    // expression at all, producing an unrecoverable `unsupportedExpression`
    // at evaluation time. A *correctly* [noprocess]-wrapped equivalent must
    // never even attempt to parse its body as Lasso — everything between
    // the open and close tags is emitted completely verbatim.
    var context = LassoContext(globals: ["x": .string("outside-still-works")])
    let output = try LassoRenderer().render(
        """
        before-[noprocess]<script>var i,j; d.MM_p[j++].src=a[i];</script>[/noprocess]-after-[$x]
        """,
        context: &context
    )
    #expect(output == "before-<script>var i,j; d.MM_p[j++].src=a[i];</script>-after-outside-still-works")
}

@Test func rendersGoldenFixtures() throws {
    let fixtureURL = try #require(Bundle.module.resourceURL?.appendingPathComponent("RenderFixtures"))
    let inputs = try FileManager.default.contentsOfDirectory(
        at: fixtureURL,
        includingPropertiesForKeys: nil
    ).filter { $0.pathExtension == "lasso" }

    #expect(inputs.count == 6)
    for input in inputs {
        let expectedURL = input.deletingPathExtension().appendingPathExtension("html")
        let source = try String(contentsOf: input, encoding: .utf8)
        let expected = try String(contentsOf: expectedURL, encoding: .utf8)
        var context = LassoContext(globals: [
            "name": .string("Ada"),
            "unsafe": .string("<strong>unsafe & raw</strong>"),
        ])
        let actual = try LassoRenderer().render(source, context: &context)
        #expect(actual == expected, "Golden mismatch for \(input.lastPathComponent)")
    }
}

@Test func invokesRegisteredNativeFunction() throws {
    var natives = LassoNativeRegistry()
    natives.register("greet") { arguments, _ in
        .string("Hello, \(arguments.first?.value.outputString ?? "friend")")
    }
    var context = LassoContext(natives: natives)
    let output = try LassoRenderer().render("[greet('Ada')]", context: &context)
    #expect(output == "Hello, Ada")
}

@Test func cacheTagIsANoOpButItsBodyStillRenders() throws {
    // Real Lasso 8's [Cache(-Name=..., -Expires=...)] ... [/Cache] wraps a
    // body of markup to memoize for a duration — this interpreter has no
    // output-caching layer, so the opening call is a no-op and the body
    // still renders normally as ordinary template content. Found live
    // -verifying a real corpus page whose template used this exact shape.
    var context = LassoContext()
    let output = try LassoRenderer().render(
        "before-[Cache(-Name='x', -Expires=10)]middle[/Cache]-after",
        context: &context
    )
    #expect(output == "before-middle-after")
}

@Test func rendersIncludesRequestSessionAndInlineFrames() throws {
    struct IncludeLoader: LassoIncludeLoader {
        func loadInclude(path: String, from includingPath: String?) throws -> String {
            #expect(path == "partials/header.lasso")
            return "<h1>[string($title)]</h1>"
        }
    }

    struct RequestProvider: LassoRequestProvider {
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

    final class SessionProvider: LassoSessionProvider, @unchecked Sendable {
        private var values: [String: LassoValue] = [:]

        func value(for name: String) -> LassoValue {
            values[name.lowercased()] ?? .null
        }

        func set(_ value: LassoValue, for name: String) throws {
            values[name.lowercased()] = value
        }
    }

    var context = LassoContext(
        globals: ["title": .string("Catalog")],
        includeLoader: IncludeLoader(),
        requestProvider: RequestProvider(),
        sessionProvider: SessionProvider(),
        inlineProvider: LassoInMemoryInlineProvider(tables: [
            "items": [
                LassoDataRow(["name": .string("Alpha"), "qty": .integer(2), "active": .string("yes")]),
                LassoDataRow(["name": .string("Beta"), "qty": .integer(3), "active": .string("yes")]),
                LassoDataRow(["name": .string("Gamma"), "qty": .integer(1), "active": .string("no")]),
            ],
        ])
    )

    let includeOutput = try LassoRenderer().render("[include:'partials/header.lasso']", context: &context)
    #expect(includeOutput == "<h1>Catalog</h1>")

    let requestOutput = try LassoRenderer().render(
        "[web_request->param('term')]|[web_request->header('host')]|[web_request->httpHost]|[cookie:'sid']",
        context: &context
    )
    #expect(requestOutput == "clogs|example.test|example.test|abc123")

    let sessionOutput = try LassoRenderer().render(
        "[session_addvar:'cart','open'][session:'cart']",
        context: &context
    )
    #expect(sessionOutput == "open")

    let inlineSource = "[inline:-search,-database='demo',-table='items',-op='eq',-active='yes',-sortfield='name']" +
        "[records][field:'name']:[field:'qty'];[/records]([found_count])[/inline]"
    let inlineOutput = try LassoRenderer().render(inlineSource, context: &context)
    #expect(inlineOutput == "Alpha:2;Beta:3;(2)")
}

@Test func parsesAndRendersLassoScriptInlineJSON() throws {
    let scriptInline = """
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

    let document = LassoParser().parse(scriptInline)
    #expect(document.diagnostics.isEmpty)
    guard case let .block(name, arguments, body, _, _, _) = document.nodes.first else {
        Issue.record("Expected script inline block")
        return
    }
    #expect(name.lowercased() == "inline")
    #expect(arguments.count == 7)
    #expect(body.count == 2)

    struct InlineProvider: LassoInlineProvider {
        func executeInline(arguments: [EvaluatedArgument], context: LassoContext) throws -> LassoInlineFrame {
            let request = LassoInlineRequest(arguments: arguments)
            #expect(request.database == "catalog_mysql")
            #expect(request.table == "skus")
            #expect(request.criteria.first?.field == "store_id")
            return LassoInlineFrame(rows: [
                LassoDataRow(["catalog_sku": .string("SKU-1"), "preview": .string("one.jpg")]),
            ])
        }
    }

    var context = LassoContext(
        globals: ["product_subset": .string("demo-product-line")],
        inlineProvider: InlineProvider()
    )
    let output = try LassoRenderer().render(scriptInline, context: &context)
    #expect(
        output == "[{\"preview\":\"one.jpg\",\"catalog_sku\":\"SKU-1\"}]" ||
            output == "[{\"catalog_sku\":\"SKU-1\",\"preview\":\"one.jpg\"}]"
    )
}

@Test func rendersCorpusFixtures() throws {
    let root = try #require(Bundle.module.resourceURL?.appendingPathComponent("CorpusFixtures"))
    let loader = try LassoFileSystemIncludeLoader(root: root)
    let inputs = try FileManager.default.contentsOfDirectory(
        at: root,
        includingPropertiesForKeys: nil
    ).filter { $0.pathExtension == "lasso" }
    #expect(inputs.count == 6)

    for input in inputs {
        let source = try String(contentsOf: input, encoding: .utf8)
        let expected = try String(
            contentsOf: input.deletingPathExtension().appendingPathExtension("html"),
            encoding: .utf8
        )
        var context = corpusFixtureContext(loader: loader, includePath: input.lastPathComponent)
        let output = try LassoRenderer().render(source, context: &context)
        #expect(
            output.trimmingCharacters(in: .newlines) == expected.trimmingCharacters(in: .newlines),
            "Corpus fixture mismatch for \(input.lastPathComponent)"
        )
    }
}

@Test func filesystemIncludeLoaderConfinesPathsAndExtensions() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("lasso-loader-\(UUID().uuidString)")
    let nested = root.appendingPathComponent("pages")
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    try "OK".write(to: root.appendingPathComponent("shared.lasso"), atomically: true, encoding: .utf8)
    try "NO".write(to: root.appendingPathComponent("secret.json"), atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: root) }

    let loader = try LassoFileSystemIncludeLoader(root: root)
    #expect(try loader.loadInclude(path: "../shared.lasso", from: "pages/home.lasso") == "OK")
    #expect(throws: LassoFileSystemIncludeError.extensionNotAllowed("json")) {
        try loader.loadInclude(path: "secret.json", from: nil)
    }
    #expect(throws: LassoFileSystemIncludeError.pathOutsideRoot("../../outside.lasso")) {
        try loader.loadInclude(path: "../../outside.lasso", from: "pages/home.lasso")
    }
}

@Test func relativeIncludeFromALeadingSlashIncludingPathResolvesWithinRoot() throws {
    // Real Lasso source overwhelmingly writes include()/library() paths
    // with a leading slash (site-root-relative), e.g.
    // include('/includes/b2b/siteconfig_cookies.inc'). A relative include
    // from *inside* that file must resolve against the site root, not
    // against the real filesystem root — found live-verifying against the
    // real corpus, where this exact shape threw pathOutsideRoot.
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("lasso-loader-\(UUID().uuidString)")
    let nested = root.appendingPathComponent("includes/b2b")
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    try "OUTER".write(to: root.appendingPathComponent("includes/siteconfig.inc"), atomically: true, encoding: .utf8)
    try "INNER".write(to: nested.appendingPathComponent("siteconfig_cookies.inc"), atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: root) }

    let loader = try LassoFileSystemIncludeLoader(root: root)
    #expect(try loader.loadInclude(path: "siteconfig_cookies.inc", from: "/includes/b2b/parent.lasso") == "INNER")
    #expect(try loader.loadInclude(path: "includes/siteconfig.inc", from: "/includes/b2b/parent.lasso") == "OUTER")
}

@Test func startupDirectoryLoadsMatchingExtensionsAndSkipsOthers() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("lasso-startup-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    try "<?lassoscript define greet => { return('hi') } ?>".write(
        to: root.appendingPathComponent("a.inc"), atomically: true, encoding: .utf8
    )
    try "<?lassoscript define farewell => { return('bye') } ?>".write(
        to: root.appendingPathComponent("b.lasso"), atomically: true, encoding: .utf8
    )
    try "{\"ignored\": true}".write(
        to: root.appendingPathComponent("c.json"), atomically: true, encoding: .utf8
    )

    let registry = LassoTagRegistry()
    let result = loadLassoStartupDirectory(
        at: root,
        allowedExtensions: ["lasso", "inc"],
        tagRegistry: registry
    )

    #expect(Set(result.loadedFiles) == ["a.inc", "b.lasso"])
    #expect(result.failedFiles.isEmpty)
    #expect(registry.containsTag(named: "greet"))
    #expect(registry.containsTag(named: "farewell"))
}

@Test func startupDirectoryContinuesPastAFailingFileAndReportsIt() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("lasso-startup-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    try "<?lassoscript define good => { return('ok') } ?>".write(
        to: root.appendingPathComponent("a-good.inc"), atomically: true, encoding: .utf8
    )
    try "<?lassoscript totallyUndefinedFunctionCall() ?>".write(
        to: root.appendingPathComponent("b-broken.inc"), atomically: true, encoding: .utf8
    )
    try "<?lassoscript define alsoGood => { return('ok too') } ?>".write(
        to: root.appendingPathComponent("c-good.inc"), atomically: true, encoding: .utf8
    )

    let registry = LassoTagRegistry()
    let result = loadLassoStartupDirectory(
        at: root,
        allowedExtensions: ["inc"],
        tagRegistry: registry
    )

    #expect(Set(result.loadedFiles) == ["a-good.inc", "c-good.inc"])
    #expect(result.failedFiles.count == 1)
    #expect(result.failedFiles.first?.file == "b-broken.inc")
    #expect(result.failedFiles.first?.error.contains("totallyUndefinedFunctionCall") == true)
    #expect(registry.containsTag(named: "good"))
    #expect(registry.containsTag(named: "alsoGood"))
}

@Test func startupDirectoryHandlesMissingDirectoryGracefully() {
    let missing = FileManager.default.temporaryDirectory
        .appendingPathComponent("lasso-startup-does-not-exist-\(UUID().uuidString)")
    let registry = LassoTagRegistry()

    let result = loadLassoStartupDirectory(
        at: missing,
        allowedExtensions: ["lasso", "inc"],
        tagRegistry: registry
    )

    #expect(result.loadedFiles.isEmpty)
    #expect(result.failedFiles.count == 1)
    #expect(result.failedFiles.first?.error == "not a directory or does not exist")
}

@Test func startupDirectoryTagsAreVisibleToLaterContextsSharingTheRegistry() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("lasso-startup-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    try "<?lassoscript define shout(msg = void) => { return(#msg + '!') } ?>".write(
        to: root.appendingPathComponent("setup.inc"), atomically: true, encoding: .utf8
    )

    let registry = LassoTagRegistry()
    let result = loadLassoStartupDirectory(at: root, allowedExtensions: ["inc"], tagRegistry: registry)
    #expect(result.failedFiles.isEmpty)

    var pageContext = LassoContext(tagRegistry: registry)
    let output = try LassoRenderer().render(
        "[shout(-msg='hello')]",
        context: &pageContext
    )
    #expect(output == "hello!")
}

@Test func dynamicInlineProviderMapsDatasourceForPerfectCRUDExecutor() throws {
    struct Executor: LassoDynamicQueryExecutor {
        func execute(_ request: LassoInlineRequest) throws -> LassoInlineFrame {
            #expect(request.database == "primary-mysql")
            #expect(request.table == "skus")
            return LassoInlineFrame(rows: [
                LassoDataRow(["mfr_style_no": .string("247")]),
            ])
        }
    }

    var context = LassoContext(inlineProvider: LassoDynamicInlineProvider(
        executor: Executor(),
        datasourceAliases: ["catalog_mysql": "primary-mysql"]
    ))
    let output = try LassoRenderer().render(
        "[inline(-database='catalog_mysql',-table='skus',-findall)][records][field('mfr_style_no')][/records][/inline]",
        context: &context
    )
    #expect(output == "247")
}

@Test func perfectCRUDExecutorMapsSearchWithoutApplicationSpecificAPI() throws {
    let executor = PerfectCRUDLassoExecutor { datasource, query in
        #expect(datasource == "catalog")
        #expect(query.table == "skus")
        #expect(query.fields == ["mfr_style_no", "color"])
        #expect(query.predicates == [
            DynamicPredicate(field: "store_id", comparison: .contains, value: .string("DEMO")),
            DynamicPredicate(field: "featured", comparison: .contains, value: .string("seasonal_sale")),
        ])
        return DynamicResult(
            rows: [
                DynamicRow(["mfr_style_no": .string("247"), "color": .string("Black")]),
                DynamicRow(["mfr_style_no": .string("701"), "color": .string("Navy")]),
            ],
            statement: "SELECT ..."
        )
    }
    var context = LassoContext(
        globals: ["product_subset": .string("DEMO")],
        inlineProvider: LassoDynamicInlineProvider(
            executor: executor,
            datasourceAliases: ["catalog_mysql": "catalog"]
        )
    )
    let output = try LassoRenderer().render(
        "[inline(-database='catalog_mysql',-table='skus',-op='cn','store_id'=$product_subset," +
            "-op='cn','featured'='seasonal_sale',-ReturnField='mfr_style_no'," +
            "-ReturnField='color',-search)][records][field('mfr_style_no')]:" +
            "[field('color')];[/records][/inline]",
        context: &context
    )
    #expect(output == "247:Black;701:Navy;")
}

@Test func customTagDefinesCallsAndIsolatesLocals() throws {
    var context = LassoContext()
    let source = """
    <?lassoscript
    define greet_tag(#name, #greeting='Hello') => {
        return #greeting + ', ' + #name + '!'
    }
    define increment_tag(#value) => {
        local(result = #value + 1)
        return #result
    }
    define short_circuit_tag(#flag) => {
        if(#flag)
            return 'early'
        /if
        return 'late'
    }
    ?>
    [greet_tag('Ada')] / [greet_tag('Bo', 'Hi')] / [local(result = 100)][increment_tag(5)] / [#result] / [short_circuit_tag(true)] / [short_circuit_tag(false)]
    """
    let output = try LassoRenderer().render(source, context: &context)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    #expect(output == "Hello, Ada! / Hi, Bo! / 6 / 100 / early / late")
}

@Test func tagExistsChecksNativeFunctionsAndCustomTags() throws {
    var nativeContext = LassoContext()
    let nativeOutput = try LassoRenderer().render(
        "[lasso_tagexists('string')]|[tag_exists('lasso_tagexists')]|[tag_exists('missing_tag')]",
        context: &nativeContext
    )
    #expect(nativeOutput == "true|true|false")

    var customContext = LassoContext()
    let customOutput = try LassoRenderer().render(
        "<?lassoscript define sample_tag() => { return 'ok' } ?>[lasso_tagexists('sample_tag')]|[tag_exists('sample_tag')]",
        context: &customContext
    )
    #expect(customOutput == "true|true")
}

@Test func typeDefinitionsConstructObjectsAndDispatchMethods() throws {
    var context = LassoContext()
    let output = try LassoRenderer().render(
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
        context: &context
    ).trimmingCharacters(in: .whitespacesAndNewlines)

    #expect(output == "Ada|Hello, Ada|Hi, Ada|integer|any")
}

@Test func customTagRecursionSucceedsAndDeepRecursionThrows() throws {
    var context = LassoContext()
    let output = try LassoRenderer().render(
        """
        <?lassoscript
        define recurse_tag(#n) => {
            if(#n <= 0)
                return 0
            /if
            return 1 + recurse_tag(#n - 1)
        }
        ?>
        [recurse_tag(3)]
        """,
        context: &context
    ).trimmingCharacters(in: .whitespacesAndNewlines)
    #expect(output == "3")

    var deepContext = LassoContext()
    #expect(throws: LassoRuntimeError.tagCallDepthExceeded) {
        try LassoRenderer().render(
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
    }
}

@Test func libraryDedupesWithinOneRenderButReloadsPerIndependentContext() throws {
    // Per LassoSoft's own library_once/[Library_Once] documentation, repeat
    // calls only no-op "if used multiple times referencing the same Lasso
    // page" — i.e. within one page's own render, not across the server
    // process's lifetime. `_begin.lasso`-style top-level executable code
    // (like a bot-exclusion check) must genuinely re-run on every request.
    final class CountingLibraryLoader: LassoIncludeLoader, @unchecked Sendable {
        private(set) var loadCount = 0
        let librarySource: String

        init(librarySource: String) {
            self.librarySource = librarySource
        }

        func loadInclude(path: String, from includingPath: String?) throws -> String {
            loadCount += 1
            return librarySource
        }
    }

    let loader = CountingLibraryLoader(librarySource: """
    <?lassoscript
    define shared_tag(#x) => {
        return #x * 2
    }
    ?>
    """)
    let registry = LassoTagRegistry()

    var firstRequestContext = LassoContext(includeLoader: loader, tagRegistry: registry)
    let firstOutput = try LassoRenderer().render(
        """
        <?lassoscript
        library('/shared.lasso')
        library('/shared.lasso')
        ?>[shared_tag(21)]
        """,
        context: &firstRequestContext
    )
    // Two `library()` calls to the same path within the SAME render only
    // load once — the within-one-page dedup real Lasso documents.
    #expect(loader.loadCount == 1)
    #expect(firstOutput == "42")

    var secondRequestContext = LassoContext(includeLoader: loader, tagRegistry: registry)
    let secondOutput = try LassoRenderer().render(
        "<?lassoscript library('/shared.lasso') ?>[shared_tag(10)]",
        context: &secondRequestContext
    )
    // A second, independent context sharing the same registry (a second
    // request) reloads and re-runs the library's top-level code again —
    // `shared_tag` stays callable because its definition persists on the
    // shared registry, but the load itself is NOT permanently cached.
    #expect(loader.loadCount == 2)
    #expect(secondOutput == "20")
}

@Test func includeAlwaysRereadsButSkipsReparseWhenUnchanged() throws {
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

    let registry = LassoTagRegistry()
    let loader = MutableIncludeLoader(content: "v1: [local(x = 1)][#x]")

    func render(_ source: String) throws -> String {
        var context = LassoContext(includeLoader: loader, tagRegistry: registry)
        return try LassoRenderer().render(source, context: &context)
    }

    #expect(try render("[include('shared.lasso')]") == "v1: 1")
    #expect(try render("[include('shared.lasso')]") == "v1: 1")
    #expect(loader.loadCount == 2, "An include is re-read (I/O) on every use, unlike a library")

    loader.content = "v2: [local(x = 2)][#x]"
    #expect(
        try render("[include('shared.lasso')]") == "v2: 2",
        "A real content change must not serve stale cached output"
    )
}

@Test func includeCacheHitsOnIdenticalSourceAndMissesOnChange() throws {
    let registry = LassoTagRegistry()
    #expect(registry.cachedInclude(forKey: "probe", matchingSource: "abc") == nil)

    let document = LassoParser().parse("abc")
    registry.cacheInclude(forKey: "probe", source: "abc", document: document)

    #expect(registry.cachedInclude(forKey: "probe", matchingSource: "abc") == document)
    #expect(registry.cachedInclude(forKey: "probe", matchingSource: "changed") == nil)
}

@Test func lassoDelimiterSupportsBraceStyleBlocks() throws {
    var context = LassoContext()
    let source = """
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
    let output = try LassoRenderer().render(source, context: &context)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    #expect(
        output == "true/yes/done",
        "Content after the closing '}' must not be swallowed into the if's body"
    )
}

@Test func lassoDelimiterBraceStyleIfElseChoosesCorrectBranch() throws {
    var context = LassoContext()

    let trueOutput = try LassoRenderer().render(
        """
        <?lasso
        if(true) => {
            $branch = 'if'
        } else => {
            $branch = 'else'
        }
        ?>
        [$branch]
        """,
        context: &context
    ).trimmingCharacters(in: .whitespacesAndNewlines)
    #expect(trueOutput == "if")

    let falseOutput = try LassoRenderer().render(
        """
        <?lasso
        if(false) => {
            $branch = 'if'
        } else => {
            $branch = 'else'
        }
        ?>
        [$branch]
        """,
        context: &context
    ).trimmingCharacters(in: .whitespacesAndNewlines)
    #expect(falseOutput == "else")
}

@Test func colonCallIfOpenerIsRecognizedAsRealControlFlow() throws {
    // Lasso 8's colon-call convention (`if:(condition);` ... `else;` ...
    // `/if;`) is just as valid an opener as the parenthesized-call style —
    // found live-verifying a real corpus page, where `if:(...)` fell
    // through to being parsed as an ordinary colon-call expression
    // statement (`if` treated as a bare function name), throwing
    // unknownFunction("if") instead of ever reaching real control flow.
    var context = LassoContext()

    let trueOutput = try LassoRenderer().render(
        """
        <?lasso
        if:(true);
            $branch = 'if'
        else;
            $branch = 'else'
        /if;
        ?>
        [$branch]
        """,
        context: &context
    ).trimmingCharacters(in: .whitespacesAndNewlines)
    #expect(trueOutput == "if")

    let falseOutput = try LassoRenderer().render(
        """
        <?lasso
        if:(false);
            $branch = 'if'
        else;
            $branch = 'else'
        /if;
        ?>
        [$branch]
        """,
        context: &context
    ).trimmingCharacters(in: .whitespacesAndNewlines)
    #expect(falseOutput == "else")
}

@Test func lassoDelimiterMixesBraceAndSlashStyleNesting() throws {
    var context = LassoContext()
    let output = try LassoRenderer().render(
        """
        <?lasso
        if(true)
            if(true) => {
                $nested = 'yes'
            }
        /if
        ?>
        [$nested]
        """,
        context: &context
    ).trimmingCharacters(in: .whitespacesAndNewlines)
    #expect(output == "yes")
}

@Test func lassoDelimiterRealCorpusShapeNoLongerThrowsUnknownFunctionIf() throws {
    var context = LassoContext()
    let output = try LassoRenderer().render(
        """
        <?lasso
        if(!$demo_setup_done) => {
            $demo_setup_done = true
        }
        ?>
        [$demo_setup_done]
        """,
        context: &context
    ).trimmingCharacters(in: .whitespacesAndNewlines)
    #expect(output == "true")
}

@Test func scriptBodyParserProducesDiagnostics() {
    let unterminated = LassoParser().parse("<?lasso if(true) => { $x = 1 ?>")
    #expect(!unterminated.diagnostics.isEmpty)

    let stray = LassoParser().parse("<?lasso } ?>")
    #expect(stray.diagnostics.contains { $0.message == "Unexpected closing brace" })

    let malformedDefine = LassoParser().parse("<?lassoscript define ?>")
    #expect(malformedDefine.diagnostics.contains { $0.message.hasPrefix("Malformed 'define'") })
}

@Test func arrowBraceBodyOnItsOwnLineIsNotMalformed() throws {
    // Real startup-folder code commonly puts the opening brace on the line
    // after '=>' rather than immediately following it (found verifying
    // against a real LassoStartup folder — a `define name(...) =>` /
    // `{` split like this used to make parseDefineOpening back out
    // entirely, silently reinterpreting the define as a plain statement
    // and later throwing unknownFunction for the tag's own name).
    var context = LassoContext()
    let output = try LassoRenderer().render(
        """
        <?lassoscript
        define greet(name = void) =>
        {
            return('hi ' + #name)
        }
        ?>
        [greet(-name='there')]
        """,
        context: &context
    ).trimmingCharacters(in: .whitespacesAndNewlines)
    #expect(output == "hi there")
}

@Test func arrowBraceIfBodyOnItsOwnLineIsRecognized() throws {
    var context = LassoContext()
    let output = try LassoRenderer().render(
        """
        <?lasso
        if(true) =>
        {
            $branch = 'taken'
        }
        ?>
        [$branch]
        """,
        context: &context
    ).trimmingCharacters(in: .whitespacesAndNewlines)
    #expect(output == "taken")
}

@Test func slashStyleBlockBodyIsNotSwallowedWhenNoArrowFollows() throws {
    // Regression guard for a bug introduced while fixing the arrow-brace
    // newline case above: consumeArrowBlockStartIfPresent() must not
    // cross a newline while merely probing for '=>' — doing so left the
    // parser positioned on the block body's first line, which the
    // caller's unconditional skipLineRemainder() then silently swallowed
    // instead of just cleaning up the block-opening line's own trailer.
    var context = LassoContext()
    let output = try LassoRenderer().render(
        """
        <?lasso
        if(true)
            $branch = 'taken'
        /if
        ?>
        [$branch]
        """,
        context: &context
    ).trimmingCharacters(in: .whitespacesAndNewlines)
    #expect(output == "taken")
}

@Test func crlfLineEndingsDoNotSwallowArrowBraceBlockBodies() throws {
    // Real corpus files are commonly CRLF-terminated (Windows-authored
    // Lasso code). Swift's Character type treats "\r\n" as a single
    // extended grapheme cluster that equals neither the standalone "\r"
    // nor "\n" Character most newline checks in this parser compare
    // against — before normalizing at TemplateScanner's entry point,
    // skipLineRemainder() (called right after an arrow-brace block opens)
    // never recognized a CRLF as "the newline it's looking for," so it
    // swallowed everything up to the next *lone* "\n" it could find —
    // in this shape, the rest of the block's body and its own closing
    // brace, silently discarding both.
    var context = LassoContext()
    let source = "<?lasso\r\nif(true) => {\r\n\t$x = 1\r\n}\r\n?>\r\n[$x]"
    let output = try LassoRenderer().render(source, context: &context)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    #expect(output == "1")
}

@Test func expressionBodiedDefineRegistersStringLiteralConstant() throws {
    // Real startup-folder shape: `define br => '<br />'` — no braces at
    // all, just a bare expression. Before this fix, parseDefineOpening
    // backed out entirely on seeing no '{', so `br` was never registered
    // and got parsed as an ordinary (undefined) function call instead.
    var context = LassoContext()
    let output = try LassoRenderer().render(
        """
        <?lasso
        define br => '<br />'
        ?>
        [br]
        """,
        context: &context
    ).trimmingCharacters(in: .whitespacesAndNewlines)
    #expect(output == "<br />")
}

@Test func expressionBodiedDefineSupportsMultiLineArrayAndMapLiterals() throws {
    // Real shape: `define botMap => array(...)` / `define keywordMap =>
    // map(...)` spanning multiple lines. readStatement()'s paren-depth
    // tracking must treat the whole multi-line call as one statement, not
    // stop at each internal newline.
    var context = LassoContext()
    let output = try LassoRenderer().render(
        """
        <?lasso
        define botMap => array(
            'SemRush',
            'DotBot'
        )
        ?>
        [botMap->get(1)]/[botMap->get(2)]/[botMap->size]
        """,
        context: &context
    ).trimmingCharacters(in: .whitespacesAndNewlines)
    #expect(output == "SemRush/DotBot/2")
}

@Test func bareIdentifierCallsZeroArgCustomTag() throws {
    var context = LassoContext()
    let output = try LassoRenderer().render(
        """
        <?lassoscript
        define greeting => { return('hello') }
        ?>
        [greeting]
        """,
        context: &context
    ).trimmingCharacters(in: .whitespacesAndNewlines)
    #expect(output == "hello")
}

@Test func typeDataMemberDefaultValueResolvesBareZeroArgTagCall() throws {
    // Mirrors the real pp_express type exactly: `data public returnURL =
    // pp_return`, where `pp_return` is itself an expression-bodied
    // zero-arg define, referenced with no parens.
    var context = LassoContext()
    let output = try LassoRenderer().render(
        """
        <?lassoscript
        define pp_return => 'https://example.com/return'
        define pp_express => type {
            data public returnURL = pp_return
        }
        local(checkout::pp_express = pp_express())
        ?>
        [#checkout->returnURL]
        """,
        context: &context
    ).trimmingCharacters(in: .whitespacesAndNewlines)
    #expect(output == "https://example.com/return")
}

@Test func withInDoIteratesArrayBindingNamedVariable() throws {
    var context = LassoContext()
    let output = try LassoRenderer().render(
        """
        <?lasso
        $collected = ''
        with x in array('a', 'b', 'c') do {
            $collected = $collected + #x
        }
        ?>
        [$collected]
        """,
        context: &context
    ).trimmingCharacters(in: .whitespacesAndNewlines)
    #expect(output == "abc")
}

@Test func withInDoIteratesOverBareZeroArgTagCallResult() throws {
    // End-to-end composition of all three fixes in this pass, mirroring
    // the real excludeBots/botMap shape exactly: a with...do body iterates
    // a bare-referenced expression-bodied array constant.
    var context = LassoContext()
    let output = try LassoRenderer().render(
        """
        <?lasso
        define botMap => array('SemRush', 'DotBot', 'AhrefsBot')
        define excludeBots(request::String) => {
            with bot in botMap do {
                if(#request->contains(#bot)) => {
                    return true
                }
            }
            return false
        }
        ?>
        [excludeBots(-request='Mozilla/5.0 SemRush Crawler')]/[excludeBots(-request='Mozilla/5.0 real browser')]
        """,
        context: &context
    ).trimmingCharacters(in: .whitespacesAndNewlines)
    #expect(output == "true/false")
}

@Test func excludeBotsFullRealShapeRedirectsUsingWebRequestHttpHost() throws {
    // The exact next gap found live-verifying excludeBots against the real
    // startup folder: excludeBots's with...do loop calls botRedirect,
    // whose body reads web_request->httpHost — reached only once a bot
    // actually matches, so this was invisible until the with...do fix
    // above unblocked the loop itself.
    struct RequestProvider: LassoRequestProvider {
        let parameters: [String: LassoValue] = [:]
        func parameter(named name: String) -> LassoValue { .void }
        func header(named name: String) -> LassoValue {
            name.lowercased() == "host" ? .string("shop.example.test") : .void
        }
        func cookie(named name: String) -> LassoValue { .void }
    }

    var context = LassoContext(requestProvider: RequestProvider())
    let output = try LassoRenderer().render(
        """
        <?lasso
        define botMap => array('SemRush', 'DotBot', 'AhrefsBot')
        define botRedirect(host::String) => {
            return 'https://' + web_request->httpHost + '/bot_response.lasso'
        }
        define excludeBots(request::String, host::String) => {
            with bot in botMap do {
                if(#request->contains(#bot)) => {
                    return botRedirect(#host)
                }
            }
            return 'no match'
        }
        ?>
        [excludeBots(-request='Mozilla/5.0 SemRush Crawler', -host='shop.example.test')]
        """,
        context: &context
    ).trimmingCharacters(in: .whitespacesAndNewlines)
    #expect(output == "https://shop.example.test/bot_response.lasso")
}

@Test func malformedWithFallsBackToOrdinaryCodeWithoutSwallowingNextStatement() throws {
    // Regression guard, same class as slashStyleBlockBodyIsNotSwallowedWhenNoArrowFollows:
    // a bare 'with' not actually followed by 'name in expr do {' must not
    // crash or eat the statement after it.
    var context = LassoContext()
    let output = try LassoRenderer().render(
        """
        <?lasso
        with = 5
        $after = 'reached'
        ?>
        [$after]
        """,
        context: &context
    ).trimmingCharacters(in: .whitespacesAndNewlines)
    #expect(output == "reached")
}

@Test func nativeReceiverIsAssignableFirstClassValue() throws {
    // The specific gap that motivated unifying native types with the
    // object system: before this, `web_request` only "worked" as a
    // receiver by spelling — it was intercepted before ever being
    // evaluated, so evaluating it as a plain identifier (e.g. via
    // assignment) yielded .null and broke immediately. Now it's a real
    // .object(LassoObjectInstance(typeName: "web_request")) value.
    struct RequestProvider: LassoRequestProvider {
        let parameters: [String: LassoValue] = ["term": .string("clogs")]
        func parameter(named name: String) -> LassoValue { parameters[name.lowercased()] ?? .void }
        func header(named name: String) -> LassoValue { .void }
        func cookie(named name: String) -> LassoValue { .void }
    }
    var context = LassoContext(requestProvider: RequestProvider())
    let output = try LassoRenderer().render(
        "<?lasso local(r = web_request) ?>[#r->param('term')]",
        context: &context
    ).trimmingCharacters(in: .whitespacesAndNewlines)
    #expect(output == "clogs")
}

@Test func webRequestMembersReflectRealRequestData() throws {
    struct RichRequestProvider: LassoRequestProvider {
        let parameters: [String: LassoValue] = ["term": .string("clogs")]
        let headers: [String: LassoValue] = [
            "host": .string("shop.example.test"),
            "user-agent": .string("Mozilla/5.0 TestAgent"),
            "accept": .string("text/html"),
        ]
        let cookies: [String: LassoValue] = ["sid": .string("abc123")]
        let requestMethod = "POST"
        let requestURI = "/checkout?term=clogs"
        let path = "/checkout"
        let isHTTPS = true
        let remoteAddress = "203.0.113.7"
        let remotePort = 54321
        let serverName = "shop.example.test"
        let serverPort = 443
        let contentType = "application/x-www-form-urlencoded"
        let contentLength = 42

        func parameter(named name: String) -> LassoValue { parameters[name.lowercased()] ?? .void }
        func header(named name: String) -> LassoValue { headers[name.lowercased()] ?? .void }
        func cookie(named name: String) -> LassoValue { cookies[name.lowercased()] ?? .void }
    }

    var context = LassoContext(requestProvider: RichRequestProvider())
    let output = try LassoRenderer().render(
        """
        [web_request->requestMethod]|\
        [web_request->requestURI]|\
        [web_request->path]|\
        [web_request->isHttps]|\
        [web_request->remoteAddr]|\
        [web_request->remotePort]|\
        [web_request->serverName]|\
        [web_request->serverPort]|\
        [web_request->contentType]|\
        [web_request->contentLength]|\
        [web_request->httpHost]|\
        [web_request->httpUserAgent]|\
        [web_request->httpAccept]|\
        [web_request->rawHeader('host')]|\
        [web_request->cookie('sid')]|\
        [web_request->param('term')]
        """,
        context: &context
    )
    #expect(output == "POST|/checkout?term=clogs|/checkout|true|203.0.113.7|54321|shop.example.test|443|" +
        "application/x-www-form-urlencoded|42|shop.example.test|Mozilla/5.0 TestAgent|text/html|" +
        "shop.example.test|abc123|clogs")

    // Bulk accessors (headers()/cookies()/params()) return a real .map,
    // verified via direct key-name member access — .map's current member
    // dispatch does plain key lookup, not method calls like ->find(key),
    // so this checks the same way ordinary Lasso map access already works
    // elsewhere in this test file.
    let bulkOutput = try LassoRenderer().render(
        "[web_request->headers->host]/[web_request->cookies->sid]/[web_request->params->term]",
        context: &context
    )
    #expect(bulkOutput == "shop.example.test/abc123/clogs")
}

@Test func webRequestPostParamsAreEmptyNotBroken() throws {
    // Documented limitation, not a silent failure: this interpreter has
    // never parsed POST bodies (tracked separately). postParam/postParams/
    // postString return empty results — the same shape a real request
    // with no matching data would produce — rather than throwing.
    var context = LassoContext()
    let output = try LassoRenderer().render(
        "[web_request->postParam('x')]|[web_request->postString]",
        context: &context
    )
    #expect(output == "|")
}

@Test func postBodySupportsRealFormDataWithPostBeforeGetOrdering() throws {
    // Documentation/post-body-support-plan.md Phase 1: real POST body data
    // reaches Lasso code now, not just wired-but-empty stubs. Duplicate
    // names, POST-before-GET combined ordering, and the joiner behavior for
    // param(name, joiner) all need real coverage, not just "doesn't throw."
    struct FormRequestProvider: LassoRequestProvider {
        let queryPairs: [LassoRequestPair] = [
            LassoRequestPair(name: "term", value: .string("from-query")),
            LassoRequestPair(name: "tag", value: .string("q1")),
            LassoRequestPair(name: "tag", value: .string("q2")),
        ]
        let postPairs: [LassoRequestPair] = [
            LassoRequestPair(name: "term", value: .string("from-post")),
            LassoRequestPair(name: "color", value: .string("red")),
            LassoRequestPair(name: "color", value: .string("blue")),
        ]
        var rawPostString: String { "term=from-post&color=red&color=blue" }

        func parameter(named name: String) -> LassoValue {
            (postPairs + queryPairs).first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value ?? .void
        }
        func header(named name: String) -> LassoValue { .void }
        func cookie(named name: String) -> LassoValue { .void }
        var parameters: [String: LassoValue] {
            Dictionary((postPairs + queryPairs).map { ($0.name.lowercased(), $0.value) }, uniquingKeysWith: { first, _ in first })
        }
        var queryParameters: [String: LassoValue] {
            Dictionary(queryPairs.map { ($0.name.lowercased(), $0.value) }, uniquingKeysWith: { first, _ in first })
        }
        var postParameters: [String: LassoValue] {
            Dictionary(postPairs.map { ($0.name.lowercased(), $0.value) }, uniquingKeysWith: { first, _ in first })
        }
    }

    var context = LassoContext(requestProvider: FormRequestProvider())
    let output = try LassoRenderer().render(
        """
        [web_request->postParam('term')]|\
        [web_request->postString]|\
        [web_request->param('term')]|\
        [web_request->queryParam('term')]|\
        [web_request->param('color', ',')]|\
        [web_request->param('color', void)->size]|\
        [client_postargs->color]|\
        [action_param('color')]|\
        [form_param('color')]
        """,
        context: &context
    )
    #expect(output == "from-post|term=from-post&color=red&color=blue|from-post|from-query|red,blue|2|red|red|red")
}

@Test func voidLookupMissBehavesLikeEmptyStringButNullStaysStrict() throws {
    // Real Lasso 9 returns `void` (not `null`) when web_request->param /
    // action_param / header / cookie lookups miss, and keeps `null` itself
    // strict — an unhandled member on a real null throws unless the type
    // defines `_unknowntag`. The real corpus's near-universal
    // `action_param('template')->size` pattern (used in a log_critical
    // line on almost every real page) crashed before this: action_param
    // returned `.null` on a miss, and `.null` had no member-dispatch case
    // at all.
    var context = LassoContext()
    let output = try LassoRenderer().render(
        "[action_param('missing')->size]|[action_param('missing')->contains('x')]|[action_param('missing')->uppercase]",
        context: &context
    )
    #expect(output == "0|false|")

    // A genuine null (not a lookup-miss void) must still throw on an
    // unhandled member — this fix must not weaken null's real strictness.
    var nullContext = LassoContext()
    #expect(throws: LassoRuntimeError.unsupportedExpression("Member bogusMember")) {
        _ = try LassoRenderer().render("[null->bogusMember]", context: &nullContext)
    }

    // The literal `void` keyword must itself parse to a real .void value
    // (previously both `null` and `void` collapsed to the same .null
    // expression node — harmless before this fix, but now `void` needs
    // its own distinct, permissive dispatch).
    var voidContext = LassoContext()
    let voidOutput = try LassoRenderer().render("[void->size]", context: &voidContext)
    #expect(voidOutput == "0")
}

@Test func webResponseMembersRecordThroughResponseSink() throws {
    final class RecordingResponseSink: LassoResponseSink, @unchecked Sendable {
        private(set) var status = 200
        private(set) var headerPairs: [(name: String, value: String)] = []
        private(set) var cookiePairs: [(name: String, value: String, secure: Bool, httpOnly: Bool)] = []

        func setStatus(_ status: Int) throws { self.status = status }
        func getStatus() -> Int { status }
        func redirect(to url: String) throws {}
        func setHeader(name: String, value: String) throws { headerPairs.append((name, value)) }
        func setCookie(name: String, value: String) throws {
            try setCookie(name: name, value: value, domain: nil, expires: nil, path: nil, secure: false, httpOnly: false)
        }
        func setCookie(
            name: String, value: String, domain: String?, expires: String?,
            path: String?, secure: Bool, httpOnly: Bool
        ) throws {
            cookiePairs.append((name, value, secure, httpOnly))
        }
    }

    let sink = RecordingResponseSink()
    var context = LassoContext(responseSink: sink)
    _ = try LassoRenderer().render(
        """
        <?lasso
        web_response->setStatus(201)
        web_response->addHeader(-name='X-Custom', -value='value1')
        web_response->replaceHeader(-name='X-Other', -value='value2')
        web_response->setCookie(-name='sid', -value='xyz', -secure, -httponly, -path='/')
        ?>
        """,
        context: &context
    )

    #expect(sink.getStatus() == 201)
    #expect(sink.headerPairs.contains { $0.name == "X-Custom" && $0.value == "value1" })
    #expect(sink.headerPairs.contains { $0.name == "X-Other" && $0.value == "value2" })
    #expect(sink.cookiePairs.count == 1)
    #expect(sink.cookiePairs.first?.name == "sid")
    #expect(sink.cookiePairs.first?.value == "xyz")
    #expect(sink.cookiePairs.first?.secure == true)
    #expect(sink.cookiePairs.first?.httpOnly == true)
}

@Test func webResponseAbortStopsRenderingLikeReturn() throws {
    // abort() rides the existing return-signal short-circuit mechanism —
    // no new control-flow needed. Verified the same way return's
    // short-circuit already is: output truncates at the abort point.
    // Needs real visible output before the abort() call to prove
    // truncation — a bare variable assignment doesn't itself produce any
    // output, so a test built only around one (as an earlier draft of
    // this test was) can't distinguish "stopped early" from "never
    // executed anything in the first place."
    var context = LassoContext()
    let output = try LassoRenderer().render(
        "BEFORE<?lasso web_response->abort() ?>AFTER",
        context: &context
    )
    #expect(output == "BEFORE")
}

@Test func sessionMembersStillWorkAfterMovingOffNativeMember() throws {
    // Regression guard: session->value/get used to be handled by the
    // now-deleted nativeMember string switch; confirm identical behavior
    // now that they're registered on the native session type instead.
    final class SessionProvider: LassoSessionProvider, @unchecked Sendable {
        private var values: [String: LassoValue] = [:]
        func value(for name: String) -> LassoValue { values[name.lowercased()] ?? .null }
        func set(_ value: LassoValue, for name: String) throws { values[name.lowercased()] = value }
    }
    var context = LassoContext(sessionProvider: SessionProvider())
    let output = try LassoRenderer().render(
        "[session_addvar:'cart','open'][session->value('cart')]/[session->get('cart')]",
        context: &context
    )
    #expect(output == "open/open")
}

@Test func protectCatchesRecoverableErrorAndSetsCurrentError() throws {
    // Documentation/error-protect-model-plan.md's core contract: protect
    // catches ONLY LassoRecoverableError, sets context.currentError, and
    // continues rendering after the block. No native tag throws this yet
    // (that lands with the inline-write-raw-sql work) — register a
    // synthetic one, matching how the plan's own test plan specifies
    // "protect catches a synthetic LassoRecoverableError."
    var natives = LassoNativeRegistry()
    natives.register("fail_with_db_error") { _, _ in
        throw LassoRecoverableError(LassoErrorState(code: 42, message: "Add failed", kind: "add"))
    }
    var context = LassoContext(natives: natives)
    let output = try LassoRenderer().render(
        "before-[protect]during-[fail_with_db_error]-unreached[/protect]-after-[error_currenterror]-[error_currenterror(-errorcode)]",
        context: &context
    )
    #expect(output == "before--after-Add failed-42")
}

@Test func protectDoesNotCatchReturnOrFatalErrors() throws {
    // return/abort ride the existing returnSignal short-circuit, not a
    // thrown error, so protect's do/catch never even sees them — but this
    // is worth a real regression test rather than trusting the mechanism
    // description. Separately, genuine fatal errors (LassoRuntimeError)
    // must stay fatal — protect only catches LassoRecoverableError.
    var returnContext = LassoContext()
    let returnOutput = try LassoRenderer().render(
        "before-[protect]during-[return('early')]-unreached[/protect]-after",
        context: &returnContext
    )
    // return('early') is a bracket expression whose evaluated value ("early")
    // is output like any other, before the returnSignal short-circuit stops
    // further rendering — so "-unreached" (inside protect, after the return)
    // and "-after" (outside protect entirely) correctly never appear, but
    // "early" itself does. This proves protect let the signal pass through
    // uncaught rather than treating it as a recoverable error to swallow.
    #expect(returnOutput == "before-during-early")

    var fatalContext = LassoContext()
    #expect(throws: LassoRuntimeError.unknownFunction("totally_undefined_native")) {
        _ = try LassoRenderer().render(
            "[protect]during-[totally_undefined_native()][/protect]-after",
            context: &fatalContext
        )
    }
}

@Test func errorCurrentErrorDefaultsToNoErrorAndInlineFramesUpdateIt() throws {
    // Milestone 3/4: a fresh context starts at real Lasso's "No Error"
    // state, and pushing an inline frame (the mechanism every inline
    // action already goes through) updates context.currentError from the
    // frame's own error state — the wiring inline-write-raw-sql-plan's
    // executor work will populate with real connector failures later.
    var context = LassoContext()
    let defaultOutput = try LassoRenderer().render(
        "[error_currenterror]/[error_currenterror(-errorcode)]",
        context: &context
    )
    #expect(defaultOutput == "No Error/0")

    context.pushInlineFrame(LassoInlineFrame(
        rows: [],
        error: LassoErrorState(code: 7, message: "Update failed", kind: "update")
    ))
    #expect(context.currentError.code == 7)
    #expect(context.currentError.message == "Update failed")
}

private func corpusFixtureContext(
    loader: any LassoIncludeLoader,
    includePath: String
) -> LassoContext {
    LassoContext(
        globals: [
            "http": .string("https://demo.example"),
            "url_prefix": .string(""),
            "response_filepath": .string("/store.lasso"),
            "product_subset": .string("DEMO"),
        ],
        includeLoader: loader,
        includePath: includePath,
        inlineProvider: LassoInMemoryInlineProvider(tables: [
            "skus": [
                LassoDataRow([
                    "store_id": .string("DEMO"), "featured": .string("seasonal_sale_top"),
                    "mfr_style_no": .string("247"), "color": .string("Black"),
                ]),
                LassoDataRow([
                    "store_id": .string("DEMO"), "featured": .string("seasonal_sale_pant"),
                    "mfr_style_no": .string("701"), "color": .string("Navy"),
                ]),
                LassoDataRow([
                    "store_id": .string("DEMO"), "featured": .string("Yes"),
                    "mfr_style_no": .string("316"), "color": .string("Wine"),
                ]),
                LassoDataRow([
                    "store_id": .string("DEMO"), "featured": .string("Yes"),
                    "mfr_style_no": .string("731"), "color": .string("Navy"),
                ]),
            ],
            "products": [
                LassoDataRow([
                    "mfr_style_no": .string("316"),
                    "short_description": .string("Stretch V-neck Top"),
                ]),
                LassoDataRow([
                    "mfr_style_no": .string("731"),
                    "short_description": .string("Cargo Jogger"),
                ]),
            ],
        ])
    )
}
