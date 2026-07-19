import Foundation
import Testing
@testable import LassoParser
import LassoPerfectCRUD
import LassoPerfectSession
@testable import LassoPerfectFileMaker
import PerfectCRUD
import PerfectFileMaker
import PerfectSessionCore

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

@Test func squareBracketScanningSkipsCommentsWhenFindingTheClosingBracket() async throws {
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
    let output = try await LassoRenderer().render(
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

@Test func noProcessPassesThroughRawContentWithoutScanningItAsLasso() async throws {
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
    let output = try await LassoRenderer().render(
        """
        before-[noprocess]<script>var i,j; d.MM_p[j++].src=a[i];</script>[/noprocess]-after-[$x]
        """,
        context: &context
    )
    #expect(output == "before-<script>var i,j; d.MM_p[j++].src=a[i];</script>-after-outside-still-works")
}

@Test func htmlCommentPassesThroughRawContentWithoutScanningItAsLasso() async throws {
    // Real Lasso's *other* documented escape hatch (Lasso 8.5 Language
    // Guide Chapter 4): plain HTML comments are just as valid as
    // [noprocess] for keeping square brackets from being interpreted —
    // its own worked example is exactly this pattern. Real corpus: 11
    // templates/*/master.template.lasso files wrap a Bootstrap modal-init
    // snippet this way (`$.HSCore.components.HSModalWindow.init(
    // '[data-modal-target]');`), which was being scanned as a real Lasso
    // bracket tag (unsupportedExpression("-modal")) before this fix.
    // Unlike [noprocess], the `<!--`/`-->` delimiters themselves are real
    // HTML syntax a browser needs to see — so they stay in the output,
    // not stripped.
    var context = LassoContext(globals: ["x": .string("outside-still-works")])
    let output = try await LassoRenderer().render(
        """
        before-<script><!-- $.init('[data-modal-target]'); // --></script>-after-[$x]
        """,
        context: &context
    )
    #expect(output == "before-<script><!-- $.init('[data-modal-target]'); // --></script>-after-outside-still-works")
}

@Test func htmlCommentDoesNotSuppressLassoDelimitersOutsideItsSpan() async throws {
    // The exemption is scoped to the comment span itself — real Lasso
    // code before/after an HTML comment on the same page still renders
    // normally, and an unterminated comment doesn't silently eat the
    // rest of the document without at least a diagnostic.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        """
        [$x = 'before'][$x]<!-- [$ignored = 'inside'] -->[$x = 'after'][$x]
        """,
        context: &context
    )
    #expect(output == "before<!-- [$ignored = 'inside'] -->after")
}

@Test func rendersGoldenFixtures() async throws {
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
        let actual = try await LassoRenderer().render(source, context: &context)
        #expect(actual == expected, "Golden mismatch for \(input.lastPathComponent)")
    }
}

@Test func invokesRegisteredNativeFunction() async throws {
    var natives = LassoNativeRegistry()
    natives.register("greet") { arguments, _ in
        .string("Hello, \(arguments.first?.value.outputString ?? "friend")")
    }
    var context = LassoContext(natives: natives)
    let output = try await LassoRenderer().render("[greet('Ada')]", context: &context)
    #expect(output == "Hello, Ada")
}

@Test func cacheTagIsANoOpButItsBodyStillRenders() async throws {
    // Real Lasso 8's [Cache(-Name=..., -Expires=...)] ... [/Cache] wraps a
    // body of markup to memoize for a duration — this interpreter has no
    // output-caching layer, so the opening call is a no-op and the body
    // still renders normally as ordinary template content. Found live
    // -verifying a real corpus page whose template used this exact shape.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        "before-[Cache(-Name='x', -Expires=10)]middle[/Cache]-after",
        context: &context
    )
    #expect(output == "before-middle-after")
}

@Test func outputAppliesDefaultHTMLEncodingUnlessEncodeNoneIsGiven() async throws {
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        "[Output: '<b>Bold</b>']|[Output: '<b>Bold</b>', -EncodeNone]",
        context: &context
    )
    #expect(output == "&lt;b&gt;Bold&lt;/b&gt;|<b>Bold</b>")
}

@Test func outputSupportsEveryDocumentedEncodingKeyword() async throws {
    // One render call per keyword — kept separate rather than one combined
    // literal, since several of these transforms are quote/backslash-heavy
    // and hard to read correctly when concatenated.
    func rendered(_ source: String) async throws -> String {
        var context = LassoContext()
        return try await LassoRenderer().render(source, context: &context)
    }

    #expect(try await rendered("[Output: 'é', -EncodeSmart]") == "&#233;")
    #expect(try await rendered("[Output: 'line1\nline2', -EncodeBreak]") == "line1<br>line2")
    #expect(try await rendered("[Output: '<a>', -EncodeXML]") == "&lt;a&gt;")
    #expect(try await rendered("[Output: 'a b', -EncodeURL]") == "a%20b")
    #expect(try await rendered("[Output: 'a&b', -EncodeStrictURL]") == "a%26b")
    #expect(try await rendered("[Output: 'hi', -EncodeBase64]") == "aGk=")
}

@Test func standaloneEncodeTagsMatchOutputsKeywordTransforms() async throws {
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        "[Encode_Smart: 'é']|[Encode_Break: 'a\nb']|[Encode_XML: '<x>']|[Encode_URL: 'a b']|" +
            "[Encode_StrictURL: 'a&b']|[Encode_SQL: 'it\\'s']|[Encode_Base64: 'hi']",
        context: &context
    )
    #expect(output == "&#233;|a<br>b|&lt;x&gt;|a%20b|a%26b|it\\'s|aGk=")
}

@Test func decodeBase64InvertsEncodeBase64ForUtf8Text() async throws {
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        "[Decode_Base64(Encode_Base64('cart-42'))]|[Decode_Base64(Encode_Base64('café'))]",
        context: &context
    )
    #expect(output == "cart-42|café")
}

@Test func decodeBase64ReturnsVoidForMalformedInput() async throws {
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        "before-[Decode_Base64('not base64')]-after",
        context: &context
    )
    #expect(output == "before--after")
}

@Test func decodeBase64StringMemberMatchesTheFreeFunction() async throws {
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        "[Decode_Base64('Y2FydC00Mg==')]|[('Y2FydC00Mg==')->decodeBase64]",
        context: &context
    )
    #expect(output == "cart-42|cart-42")
}

@Test func decodeBase64CanFeedInlineSearchCriteria() async throws {
    var context = LassoContext(inlineProvider: LassoInMemoryInlineProvider(tables: [
        "carts": [
            LassoDataRow(["cart_id": .string("cart-42"), "status": .string("hit")]),
            LassoDataRow(["cart_id": .string("cart-99"), "status": .string("miss")]),
        ],
    ]))

    let output = try await LassoRenderer().render(
        "[inline(-database='catalog',-table='carts',-search,'cart_id'=Decode_Base64('Y2FydC00Mg=='))][records][field('status')][/records][/inline]",
        context: &context
    )
    #expect(output == "hit")
}

@Test func dynamicVariableAsAnUnlabeledArgumentResolvesToItsValueAsTheKeyword() async throws {
    // `#dynamicField = value` — real corpus: pages/detail.page.lasso's
    // `#product_search = #search_by` inside an Inline(...) -search call,
    // where #product_search holds 'mfr_style_no' or 'scrubs_style_color'
    // at runtime, picking which column the search filters on. Previously
    // this fell through to `assignmentLabel`, which also matches
    // `.variable` and returned the variable's own NAME
    // ("product_search") used verbatim as a raw SQL column — this test
    // covers both real values, plus the sibling literal-labeled argument
    // ('active'='active', matching the real call's exact shape) staying
    // unaffected in the same call.
    var context = LassoContext(inlineProvider: LassoInMemoryInlineProvider(tables: [
        "skus": [
            LassoDataRow(["mfr_style_no": .string("ABC"), "scrubs_style_color": .string("ABC-Red"), "active": .string("active"), "swatch_image": .string("abc.jpg")]),
            LassoDataRow(["mfr_style_no": .string("XYZ"), "scrubs_style_color": .string("XYZ-Blue"), "active": .string("active"), "swatch_image": .string("xyz.jpg")]),
        ],
    ]))

    let byStyleNumber = try await LassoRenderer().render(
        "[local(product_search::string='mfr_style_no')][local(search_by::string='ABC')]" +
        "[inline(-database='catalog',-table='skus','active'='active',#product_search=#search_by,-search)]" +
        "[records][field('swatch_image')][/records][/inline]",
        context: &context
    )
    #expect(byStyleNumber == "abc.jpg")

    let byStyleColor = try await LassoRenderer().render(
        "[local(product_search::string='scrubs_style_color')][local(search_by::string='XYZ-Blue')]" +
        "[inline(-database='catalog',-table='skus','active'='active',#product_search=#search_by,-search)]" +
        "[records][field('swatch_image')][/records][/inline]",
        context: &context
    )
    #expect(byStyleColor == "xyz.jpg")
}

@Test func dynamicArgumentKeywordRejectsAnUnsafeResolvedFieldName() async throws {
    // Once a variable's runtime VALUE can become a raw SQL column name
    // (DynamicPredicate.field in PerfectCRUDLassoExecutor.swift),
    // Perfect-MySQL's `quote(identifier:)` only wraps it in backticks —
    // it does not escape embedded backticks — so an unvalidated dynamic
    // label would be a real SQL identifier-injection path. This is
    // defense-in-depth: nothing in the real corpus sets this variable
    // from untrusted input today, but the interpreter itself can't know
    // that's true for every page, so it validates unconditionally.
    var context = LassoContext(inlineProvider: LassoInMemoryInlineProvider(tables: ["skus": []]))
    await #expect(throws: LassoRuntimeError.unsafeDynamicFieldName("mfr_style_no`; DROP TABLE skus; --")) {
        _ = try await LassoRenderer().render(
            "[local(product_search::string='mfr_style_no`; DROP TABLE skus; --')][local(search_by::string='ABC')]" +
            "[inline(-database='catalog',-table='skus',#product_search=#search_by,-search)]",
            context: &context
        )
    }
}

@Test func inlineTableReturnFieldSortFieldKeyFieldArgumentsRejectUnsafeValues() async throws {
    // -Table/-ReturnField/-SortField/-KeyField argument VALUES reach the
    // same unescaped SQL-identifier sink (DynamicQuery/DynamicMutation.table,
    // DynamicQuery.fields, DynamicOrdering.field, DynamicPredicate.field via
    // keyField) as the #var = value dynamic label fixed above — but they
    // were never validated at all, since they're ordinary labeled arguments,
    // not the `.assignment`-shaped case that fix covered. Real corpus:
    // components/inSite/results_navigation.inc builds `-sortfield=$sortCol`
    // directly from `action_param('sortfield')`, completely unvalidated.
    var context = LassoContext(inlineProvider: LassoInMemoryInlineProvider(tables: [:]))
    let unsafe = "skus`; DROP TABLE skus; --"

    await #expect(throws: LassoRuntimeError.unsafeDynamicFieldName(unsafe)) {
        _ = try await LassoRenderer().render(
            "[inline(-database='catalog',-table='\(unsafe)',-search)]",
            context: &context
        )
    }
    await #expect(throws: LassoRuntimeError.unsafeDynamicFieldName(unsafe)) {
        _ = try await LassoRenderer().render(
            "[inline(-database='catalog',-table='skus',-returnfield='\(unsafe)',-search)]",
            context: &context
        )
    }
    await #expect(throws: LassoRuntimeError.unsafeDynamicFieldName(unsafe)) {
        _ = try await LassoRenderer().render(
            "[inline(-database='catalog',-table='skus',-sortfield='\(unsafe)',-search)]",
            context: &context
        )
    }
    await #expect(throws: LassoRuntimeError.unsafeDynamicFieldName(unsafe)) {
        _ = try await LassoRenderer().render(
            "[inline(-database='catalog',-table='skus',-keyfield='\(unsafe)',-keyvalue=1,-update)]",
            context: &context
        )
    }
}

@Test func inlineTableReturnFieldSortFieldKeyFieldAcceptRealCorpusLiteralShapes() async throws {
    // Guards against over-tightening the regex — real corpus usage
    // (pages_internal/categories.lasso and others): plain identifier-shaped
    // literals must keep working unaffected.
    var context = LassoContext(inlineProvider: LassoInMemoryInlineProvider(tables: [
        "ca_web": [
            LassoDataRow(["id": .integer(1), "category_name": .string("Tops")]),
        ],
    ]))
    let output = try await LassoRenderer().render(
        "[inline(-database='catalog',-table='CA_web','id'='1',-returnfield='category_name',-sortfield='category_name',-keyfield='id',-search)]" +
        "[records][field('category_name')][/records][/inline]",
        context: &context
    )
    #expect(output == "Tops")
}

@Test func inlineSortFieldRejectsTheExactResultsNavigationBacktickInjectionShape() async throws {
    // Reproduces components/inSite/results_navigation.inc's real shape:
    // `var('sortCol') = (action_param('sortfield') ? action_param('sortfield') | 'ID')`
    // then `-sortfield=$sortCol` — a request-parameter-derived value used
    // directly as a dynamic sort-field argument, with no validation before
    // this fix. `#sortCol` here stands in for the real `action_param`
    // read; the vulnerability is in what happens to the resolved STRING
    // once it reaches -SortField, not in how it got populated.
    var context = LassoContext(inlineProvider: LassoInMemoryInlineProvider(tables: [:]))
    let unsafe = "ID`; DROP TABLE skus; --"
    await #expect(throws: LassoRuntimeError.unsafeDynamicFieldName(unsafe)) {
        _ = try await LassoRenderer().render(
            "[var(sortCol::string='\(unsafe)')]" +
            "[inline(-database='catalog',-table='skus',-sortfield=$sortCol,-search)]",
            context: &context
        )
    }
}

// Expected values computed independently via Python's stdlib hmac/hashlib
// (not hand-derived or quoted from memory) for key="key",
// message="The quick brown fox jumps over the lazy dog" — the standard
// textbook HMAC worked example. See
// Documentation/outstanding-compatibility-project-plans.md.
@Test func encryptHmacSha1HexMatchesKnownVector() async throws {
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        "[Encrypt_HMAC(-token='The quick brown fox jumps over the lazy dog', -password='key', -digest='sha1', -hex)]",
        context: &context
    )
    #expect(output == "0xde7c9b85b8b78aa6bc8a7a36f70a90701c9db4d9")
}

@Test func encryptHmacSha1Base64MatchesRealCorpusArgumentShape() async throws {
    // -Token=/-Password=/-Digest='sha1'/-Base64 is real corpus's exact
    // shape (password-reset token generation).
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        "[Encrypt_HMAC(-Token='The quick brown fox jumps over the lazy dog', -Password='key', -Digest='sha1', -Base64)]",
        context: &context
    )
    #expect(output == "3nybhbi3iqa8ino29wqQcBydtNk=")
}

@Test func encryptHmacUnrecognizedDigestDefaultsToMD5() async throws {
    // No confirmed doc answer for an unrecognized -Digest value —
    // defaults to MD5 (the tag's own documented default), matching this
    // codebase's established "unknown keyword -> benign fallback, not a
    // thrown error" convention rather than LassoRecoverableError (which
    // this codebase reserves for genuinely missing required arguments).
    var context = LassoContext()
    let missingDigest = try await LassoRenderer().render(
        "[Encrypt_HMAC(-token='The quick brown fox jumps over the lazy dog', -password='key', -base64)]",
        context: &context
    )
    let unrecognizedDigest = try await LassoRenderer().render(
        "[Encrypt_HMAC(-token='The quick brown fox jumps over the lazy dog', -password='key', -digest='not-a-real-digest', -base64)]",
        context: &context
    )
    let expectedMD5Base64 = "gAcHE0Y+d0m5DC3CSRHidQ=="
    #expect(missingDigest == expectedMD5Base64)
    #expect(unrecognizedDigest == expectedMD5Base64)
}

@Test func encryptHmacWithNoOutputFlagFallsBackToLossyRawBytes() async throws {
    // Documented limitation: no LassoValue bytes case exists (same known
    // gap Decode_Base64 already lives with), so the raw-bytes path (no
    // -Base64/-Hex/-Cram) lossily decodes as UTF-8 rather than crashing —
    // low-stakes since real corpus usage is always -Base64.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        "[Encrypt_HMAC(-token='x', -password='key')]",
        context: &context
    )
    #expect(output.isEmpty == false)
}

@Test func encryptHmacRequiresPasswordAndToken() async throws {
    // -Password/-Token are both documented as required PARAMETERS — the
    // tag must be called with both specified at all — matching
    // File_ProcessUploads's missing -Destination precedent: throw a
    // recoverable error, catchable by [protect], not a silent fallback.
    // This is about the argument being OMITTED entirely, not about its
    // value being empty -- see encryptHmacAcceptsExplicitlyEmptyTokenOrPassword
    // just below for why an empty-but-present value must NOT throw.
    var context = LassoContext()
    let missingPassword = try await LassoRenderer().render(
        "[protect][Encrypt_HMAC(-token='x')][/protect][error_currenterror]",
        context: &context
    )
    #expect(missingPassword == "Encrypt_HMAC requires -Password.")

    let missingToken = try await LassoRenderer().render(
        "[protect][Encrypt_HMAC(-password='key')][/protect][error_currenterror]",
        context: &context
    )
    #expect(missingToken == "Encrypt_HMAC requires -Token.")
}

@Test func encryptHmacAcceptsExplicitlyEmptyTokenOrPassword() async throws {
    // Confirmed live 2026-07-18 against a real site: a login-check include
    // unconditionally calls Encrypt_HMAC(-token = $password, -password =
    // 'key', ...) where $password is '' outside a login attempt -- and a
    // real Lasso site does NOT error on this. The tag's documented
    // "requires -Password/-Token" means the parameters must be specified
    // in the call, not that their values must be non-empty; an explicit
    // empty string is a valid input (the HMAC of an empty message). An
    // earlier version of this guard incorrectly rejected both cases alike.
    var context = LassoContext()
    let emptyToken = try await LassoRenderer().render(
        "[Encrypt_HMAC(-token='', -password='key', -digest='sha1', -hex)]",
        context: &context
    )
    #expect(emptyToken.isEmpty == false)
    #expect(emptyToken.hasPrefix("0x"))

    let emptyPassword = try await LassoRenderer().render(
        "[Encrypt_HMAC(-token='x', -password='', -digest='sha1', -hex)]",
        context: &context
    )
    #expect(emptyPassword.isEmpty == false)
    #expect(emptyPassword.hasPrefix("0x"))
}

@Test func logCriticalIsANoOpWhenNoDiagnosticLogSinkIsWired() async throws {
    // Pre-existing behavior for any host that doesn't wire a sink --
    // log_critical must never throw or produce output of its own.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        "BEFORE[log_critical('something happened')]AFTER",
        context: &context
    )
    #expect(output == "BEFOREAFTER")
}

@Test func logCriticalForwardsItsMessageToTheWiredDiagnosticLogSink() async throws {
    final class Capture: @unchecked Sendable {
        var messages: [String] = []
    }
    let capture = Capture()
    var context = LassoContext(diagnosticLogSink: { message in
        capture.messages.append(message)
    })
    let output = try await LassoRenderer().render(
        "BEFORE[log_critical('something happened')]AFTER",
        context: &context
    )
    #expect(output == "BEFOREAFTER")
    #expect(capture.messages == ["something happened"])
}

// Confirmed against reference.lassosoft.com (LassoSoft's own canonical tag
// reference) and lassoguide.com, not just the local 8.5 PDF -- confirmed
// live 2026-07-18 that no Lasso 9 dot-notation equivalent exists (real
// corpus and LP9Docs both only ever use the classic tag-call form).
@Test func validEmailAcceptsAPlausiblyFormattedAddress() async throws {
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        "[Valid_Email('person@example.com')]",
        context: &context
    )
    #expect(output == "true")
}

@Test func validEmailRejectsTextWithNoAtSignOrDomain() async throws {
    var context = LassoContext()
    let missingAtSign = try await LassoRenderer().render(
        "[Valid_Email('not-an-email')]",
        context: &context
    )
    let missingDomain = try await LassoRenderer().render(
        "[Valid_Email('person@')]",
        context: &context
    )
    #expect(missingAtSign == "false")
    #expect(missingDomain == "false")
}

// reference.lassosoft.com documents -HostName/-Domain/-StandardDomains --
// real corpus never uses any of these (every call site is a single
// positional argument), but they're implemented per this project's
// established convention of matching documented semantics over corpus-only
// inference.
@Test func validEmailHostNameRequiresAnExactCaseInsensitiveMatch() async throws {
    var context = LassoContext()
    let matching = try await LassoRenderer().render(
        "[Valid_Email('person@Example.com', -HostName='example.com')]",
        context: &context
    )
    let mismatched = try await LassoRenderer().render(
        "[Valid_Email('person@example.com', -HostName='other.com')]",
        context: &context
    )
    #expect(matching == "true")
    #expect(mismatched == "false")
}

@Test func validEmailDomainRestrictsToACommaSeparatedTLDList() async throws {
    var context = LassoContext()
    let allowed = try await LassoRenderer().render(
        "[Valid_Email('person@example.com', -Domain='com,net')]",
        context: &context
    )
    let disallowed = try await LassoRenderer().render(
        "[Valid_Email('person@example.io', -Domain='com,net')]",
        context: &context
    )
    #expect(allowed == "true")
    #expect(disallowed == "false")
}

@Test func validEmailStandardDomainsAcceptsTheDocumentedTLDSet() async throws {
    var context = LassoContext()
    let eduAllowed = try await LassoRenderer().render(
        "[Valid_Email('person@example.edu', -StandardDomains)]",
        context: &context
    )
    let ioRejected = try await LassoRenderer().render(
        "[Valid_Email('person@example.io', -StandardDomains)]",
        context: &context
    )
    #expect(eduAllowed == "true")
    #expect(ioRejected == "false")
}

// Known-valid/invalid test numbers are the standard Luhn textbook examples,
// not real card numbers. reference.lassosoft.com's own page says "ROT-13
// algorithm" verbatim -- confirmed this isn't an artifact of this
// project's PDF text extraction, it's the actual published text -- but
// it's still almost certainly a substantive documentation defect: ROT-13
// has no defined operation on numeric digits, and the same page's own
// claimed behavior (validates real Visa/Mastercard/AmEx/Discover numbers)
// exactly matches Luhn, the real, universal standard for this purpose.
@Test func validCreditCardAcceptsAKnownLuhnValidNumber() async throws {
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        "[Valid_CreditCard('4111111111111111')]",
        context: &context
    )
    #expect(output == "true")
}

@Test func validCreditCardRejectsAKnownLuhnInvalidNumber() async throws {
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        "[Valid_CreditCard('4111111111111112')]",
        context: &context
    )
    #expect(output == "false")
}

@Test func validCreditCardAcceptsDashSeparatedDigitGroups() async throws {
    // Self-caught bug in the first draft: filtering only whitespace (not
    // dashes) before the all-digit check would reject this real-world
    // input shape outright.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        "[Valid_CreditCard('4111-1111-1111-1111')]",
        context: &context
    )
    #expect(output == "true")
}

@Test func validCreditCardRejectsNonNumericInput() async throws {
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        "[Valid_CreditCard('not-a-card-number')]",
        context: &context
    )
    #expect(output == "false")
}

@Test func validCreditCardRejectsAnAllZeroNumberMatchingTheDocumentedExample() async throws {
    // reference.lassosoft.com's own worked example:
    // [Valid_CreditCard: '0000000000000000'] => False. A bare Luhn checksum
    // can't distinguish this from valid (0 is trivially a multiple of 10),
    // so this needs its own explicit guard beyond the checksum math --
    // caught by cross-checking the reference site's documented example,
    // not by any corpus usage (real corpus never submits all-zero input).
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        "[Valid_CreditCard('0000000000000000')]",
        context: &context
    )
    #expect(output == "false")
}

@Test func currencyDefaultsToEnUSLocale() async throws {
    var context = LassoContext()
    let output = try await LassoRenderer().render("[currency(1234.56)]", context: &context)
    #expect(output == "$1,234.56")
}

@Test func percentAppliesDocumentedMultiplyByHundredForAFractionalInput() async throws {
    // Real corpus confirms $welcome_discount is stored as a fraction, not
    // a whole percentage (includes/cart_count.include.lasso:
    // Integer(100.00 * decimal($welcome_discount))) — NumberFormatter's
    // default percentStyle behavior (multiply by 100) is correct as-is
    // for this shape, no multiplier override needed.
    var context = LassoContext()
    let output = try await LassoRenderer().render("[percent(0.05)]", context: &context)
    #expect(output == "5%")
}

@Test func currencyAndPercentAcceptPositionalLanguageAndCountryOverrides() async throws {
    // Documented signature: one required number, then optional positional
    // (not -flag=) language/country codes — matching real corpus, which
    // never exercises positions 1/2, but the documented contract does.
    // German locale is a distinct-enough test that the language/country
    // parameters actually took effect (comma/period grouping swap),
    // without hardcoding the exact currency symbol placement.
    var context = LassoContext()
    let output = try await LassoRenderer().render("[currency(1234.56, 'de', 'DE')]", context: &context)
    #expect(output.contains("1.234,56"))
}

// MARK: - [Select]/[Case]/[/Select] (Lasso 8.5 Ch. 16 "Conditional Logic")
//
// Lowered into the existing if/else-if/else block representation at parse
// time (BlockBuilder.swift) — no new AST node, no new Renderer code. See
// Documentation/outstanding-compatibility-project-plans.md item 10.

@Test func selectCaseBracketParenCallLowersToIfElseChain() async throws {
    let source = "[Select($x)][Case('1')]one[Case('2')]two[Case]default[/Select]"

    var contextOne = LassoContext(globals: ["x": .string("1")])
    #expect(try await LassoRenderer().render(source, context: &contextOne) == "one")

    var contextTwo = LassoContext(globals: ["x": .string("2")])
    #expect(try await LassoRenderer().render(source, context: &contextTwo) == "two")

    var contextOther = LassoContext(globals: ["x": .string("nope")])
    #expect(try await LassoRenderer().render(source, context: &contextOther) == "default")
}

@Test func selectCaseColonCallProducesIdenticalOutputToParenCall() async throws {
    // Proves the parser-unification claim end-to-end (not just at the
    // ExpressionParser unit level): `(` and `:` postfix calls already
    // produce the identical .call node, so [Case: 1] and [Case('1')]
    // parse — and render — identically with zero dedicated colon-call
    // handling for Case.
    let parenForm = "[Select($season)][Case('1')]spring[Case('2')]summer[/Select]"
    let colonForm = "[Select($season)][Case: 1]spring[Case: 2]summer[/Select]"

    for season in ["1", "2"] {
        var parenContext = LassoContext(globals: ["season": .string(season)])
        var colonContext = LassoContext(globals: ["season": .string(season)])
        let parenOutput = try await LassoRenderer().render(parenForm, context: &parenContext)
        let colonOutput = try await LassoRenderer().render(colonForm, context: &colonContext)
        #expect(parenOutput == colonOutput)
    }
}

@Test func selectCaseColonCallCoercesBareIntegerAgainstAStringSelectValue() async throws {
    // Real corpus shape (includes/b2b/huguley/top_right.lasso): bare
    // unquoted integer Case values compared against a Field()-sourced
    // string. Lowering emits selectValue == caseValue as a literal binary
    // node, reusing Evaluator.binary's existing coercive/string-based
    // "==" — the same equality every other == in this language uses, not
    // an invented comparison rule.
    let source = "[Select(Season)][Case: 1]spring[Case: 2]summer[/Select]"
    var context = LassoContext(globals: ["season": .string("2")])
    #expect(try await LassoRenderer().render(source, context: &context) == "summer")
}

@Test func selectCaseFreeTagSemicolonFormMatchesBracketForms() async throws {
    // Real corpus shape (includes/Calculate_Day.include.lasso): no
    // brackets at all, semicolon-terminated, lassoscript-mode.
    let source = """
    <?lassoscript
    Select(Integer($day));
    Case(1);
    'Sunday';
    Case(2);
    'Monday';
    /Select;
    ?>
    """
    var contextOne = LassoContext(globals: ["day": .integer(1)])
    #expect(try await LassoRenderer().render(source, context: &contextOne) == "Sunday")

    var contextTwo = LassoContext(globals: ["day": .integer(2)])
    #expect(try await LassoRenderer().render(source, context: &contextTwo) == "Monday")
}

@Test func selectCaseSecondBareDefaultIsUnreachable() async throws {
    // Lasso 8.5: "the first Case tag without any value is returned as the
    // default value" — a second bare Case after the first is truncated
    // during lowering, not left to incidental parser behavior.
    let source = "[Select($x)][Case('9')]nope[Case]first-default[Case]second-default[/Select]"

    var matchContext = LassoContext(globals: ["x": .string("9")])
    #expect(try await LassoRenderer().render(source, context: &matchContext) == "nope")

    var defaultContext = LassoContext(globals: ["x": .string("other")])
    #expect(try await LassoRenderer().render(source, context: &defaultContext) == "first-default")
}

@Test func selectCaseFallsThroughToNothingWhenNoCaseMatchesAndNoDefault() async throws {
    // Matches `if` with no `else`: alternate ?? [] renders empty.
    let source = "[Select($x)][Case('1')]one[/Select]"
    var context = LassoContext(globals: ["x": .string("9")])
    #expect(try await LassoRenderer().render(source, context: &context) == "")
}

@Test func selectCaseWithNoCaseTagsAtAllRendersNothing() async throws {
    // Degenerate but valid: an empty branch list lowers to an empty node
    // list, not a crash.
    let source = "before[Select($x)][/Select]after"
    var context = LassoContext(globals: ["x": .string("1")])
    #expect(try await LassoRenderer().render(source, context: &context) == "beforeafter")
}

@Test func selectCaseWithOnlyABareDefaultAlwaysRendersIt() async throws {
    // No valued Case at all before the default — the fold produces the
    // default's body unconditionally, with no wrapping `if`.
    let source = "[Select($x)][Case]always[/Select]"
    var context = LassoContext(globals: ["x": .string("anything")])
    #expect(try await LassoRenderer().render(source, context: &context) == "always")
}

@Test func stringMembersExposeTheSameEncodingsAsLasso9Methods() async throws {
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        "[('é')->encodeSmart]|[('a\nb')->encodeBreak]|[('<x>')->encodeXML]|" +
            "[('a&b')->encodeStrictURL]|[('it\\'s')->encodeSQL]|[('hi')->encodeBase64]",
        context: &context
    )
    #expect(output == "&#233;|a<br>b|&lt;x&gt;|a%26b|it\\'s|aGk=")
}

@Test func outputNoneSuppressesRenderedTextButStillRunsItsBody() async throws {
    // Real corpus shape: a bare colon-call statement with no parens at
    // all, common at the top of startup/page files
    // (`Output_None; var(...); /Output_None;`). Side effects (the
    // variable assignment) must still happen even though no text reaches
    // the page.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        """
        before-[
        Output_None;
            Var: 'hidden' = 'set';
        /Output_None;
        ]-after-[Var: 'hidden']
        """,
        context: &context
    )
    #expect(output == "before--after-set")
}

@Test func htmlCommentWrapsRenderedOutput() async throws {
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        "before-[HTML_Comment]middle[/HTML_Comment]-after",
        context: &context
    )
    #expect(output == "before-<!--middle-->-after")
}

@Test func encodeSetChangesTheDefaultForNestedOutputCallsWithNoExplicitKeyword() async throws {
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        "[Encode_Set: -EncodeNone][Output: '<b>Bold</b>'][/Encode_Set]|[Output: '<b>Bold</b>']",
        context: &context
    )
    // Inside Encode_Set(-EncodeNone), Output with no keyword of its own
    // uses the scope's default; outside it, Output falls back to HTML.
    #expect(output == "<b>Bold</b>|&lt;b&gt;Bold&lt;/b&gt;")
}

@Test func dateParsesRecognizedStringFormats() async throws {
    func rendered(_ source: String) async throws -> String {
        var context = LassoContext()
        return try await LassoRenderer().render(source, context: &context)
    }

    // US M/d/yyyy, US with time, ISO, ISO with time, compact yyyyMMddHHmmss —
    // every recognized shape reformatted to the same %Q %T output so a
    // single assertion per format proves the parse actually worked.
    #expect(try await rendered("[Date_Format('6/14/2001', -Format='%Q %T')]") == "2001-06-14 00:00:00")
    #expect(try await rendered("[Date_Format('6/14/2001 15:05:03', -Format='%Q %T')]") == "2001-06-14 15:05:03")
    #expect(try await rendered("[Date_Format('2001-06-14', -Format='%Q %T')]") == "2001-06-14 00:00:00")
    #expect(try await rendered("[Date_Format('2001-06-14 15:05:03', -Format='%Q %T')]") == "2001-06-14 15:05:03")
    #expect(try await rendered("[Date_Format('20010614150503', -Format='%Q %T')]") == "2001-06-14 15:05:03")
}

@Test func dateHonorsAnExplicitFormatOverrideWhenParsingAnAmbiguousString() async throws {
    var context = LassoContext()
    // -Format on Date's own construction forces how the string is read,
    // rather than falling through the recognized-format list.
    let output = try await LassoRenderer().render(
        "[Date_Format(Date('14-06-2001', -Format='%d-%m-%Y'), -Format='%Q')]",
        context: &context
    )
    #expect(output == "2001-06-14")
}

@Test func dateFormatSupportsTheLanguageGuidesOwnWorkedExample() async throws {
    var context = LassoContext()
    // Lasso 8.5 Language Guide Chapter 29's own worked example:
    // [Date_Format: '06/14/2001', -Format='%A, %B %d'] -> Thursday, June 14
    let output = try await LassoRenderer().render(
        "[Date_Format: '06/14/2001', -Format='%A, %B %d']",
        context: &context
    )
    #expect(output == "Thursday, June 14")
}

@Test func dateFormatSupportsEveryCorpusObservedAndDocumentedSymbol() async throws {
    var context = LassoContext()
    // 2001-06-14 15:05:03 GMT is a Thursday — one fixed instant covers
    // every corpus-observed symbol (%B %Y %Q %D %T %a %m %H %M %S %r %w %d)
    // plus representative coverage of the rest of the documented table
    // (%A %b %y %h %p %z %Z %G) and the %% literal, in one render call.
    let output = try await LassoRenderer().render(
        """
        [Date_Format('2001-06-14 15:05:03', -Format=\
        '%B|%Y|%Q|%D|%T|%a|%A|%m|%H|%M|%S|%r|%w|%d|%b|%y|%h|%p|%G|%%')]
        """,
        context: &context
    )
    let fields = output.components(separatedBy: "|")
    #expect(fields == [
        "June", "2001", "2001-06-14", "06/14/2001", "15:05:03", "Thu", "Thursday",
        "06", "15", "05", "03", "03:05:03 PM", "5", "14", "Jun", "01", "03", "PM", "GMT", "%",
    ])
}

@Test func dateFormatWeekOfYearRendersAsAZeroPaddedTwoDigitNumber() async throws {
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        "[Date_Format('2001-06-14', -Format='%W')]",
        context: &context
    )
    #expect(output.count == 2 && output.allSatisfy(\.isNumber), "no precise corpus/doc example for %W's exact value — just its shape")
}

@Test func dateFormatPaddingModifiersControlLeadingZeroesAndSpaces() async throws {
    var context = LassoContext()
    // 2001-06-04: a single-digit day, to distinguish the three padding
    // behaviors (%d zero-padded, %_d space-padded, %-d unpadded).
    let output = try await LassoRenderer().render(
        "[Date_Format('2001-06-04', -Format='%d|%_d|%-d')]",
        context: &context
    )
    #expect(output == "04| 4|4")
}

@Test func dateConstructsFromYearMonthDayKeywords() async throws {
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        "[Date_Format(Date(-Year=2001, -Month=6, -Day=14, -Hour=15, -Minute=5, -Second=3), -Format='%Q %T')]",
        context: &context
    )
    #expect(output == "2001-06-14 15:05:03")
}

@Test func dateLocalToGMTAndGMTToLocalRoundTrip() async throws {
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        "[Date_Format(Date_LocalToGMT(Date_GMTToLocal(Date('2001-06-14 15:05:03'))), -Format='%Q %T')]",
        context: &context
    )
    #expect(output == "2001-06-14 15:05:03")
}

@Test func dateFormatMethodMatchesTheFreeFunctionTagForTheSameInput() async throws {
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        "[Date_Format(Date('2001-06-14 15:05:03'), -Format='%Q %T')]|" +
            "[(Date('2001-06-14 15:05:03'))->format('%Q %T')]",
        context: &context
    )
    let parts = output.components(separatedBy: "|")
    #expect(parts.count == 2 && parts[0] == parts[1], "Lasso 8 tag style and Lasso 9 method style must produce identical output")
}

@Test func dateFormatAcceptsABareDateArgumentMeaningNow() async throws {
    var context = LassoContext()
    // The most common real corpus shape: a bare `Date` identifier (no
    // parens) as the positional argument — resolves to "now", so only the
    // output shape (not an exact value) can be asserted.
    let output = try await LassoRenderer().render(
        "[Date_Format(Date, -Format='%D')]",
        context: &context
    )
    let parts = output.components(separatedBy: "/")
    #expect(parts.count == 3 && parts[0].count == 2 && parts[1].count == 2 && parts[2].count == 4)
}

@Test func dateFieldAccessorsExposeTheAlreadyStoredComponents() async throws {
    // lassoguide.com date-duration.html — `->year()`/`->month()`/`->day()`/
    // `->hour()`/`->minute()`/`->second()`/`->dayOfWeek()` were entirely
    // missing before this; `LassoDateComponents` already stored every one
    // of these fields internally (`date_format` could always render them
    // via `%Y`/`%m`/etc.), but there was no direct accessor — forcing any
    // date-comparison/date-math need through string formatting instead.
    // 2001-06-14 was a Thursday.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        "[var(d = Date('2001-06-14 15:05:03'))]" +
            "[$d->year]-[$d->month]-[$d->day]-[$d->dayOfMonth] " +
            "[$d->hour]:[$d->minute]:[$d->second] dow=[$d->dayOfWeek]",
        context: &context
    )
    #expect(output.contains("2001-6-14-14"))
    #expect(output.contains("15:5:3"))
    // Sunday=1...Saturday=7 (Lasso's own numbering, matches Calendar's
    // .weekday for Gregorian) — Thursday is day 5.
    #expect(output.contains("dow=5"))
}

@Test func dateAsIntegerReturnsEpochSeconds() async throws {
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        "[(Date('1970-01-02'))->asInteger]",
        context: &context
    )
    #expect(output == "86400")
}

@Test func dateAddAndDateSubtractFreeTagsSupportEveryDocumentedUnit() async throws {
    // Lasso 8.5 Language Guide Ch. 29 Table 6, confirmed by reading the
    // PDF directly — first parameter is the date, keyword parameters name
    // the unit(s) to add/subtract: -Second/-Minute/-Hour/-Day/-Week/
    // -Month/-Year. Explicitly planned in this project's own backlog
    // (Documentation/outstanding-compatibility-project-plans.md's Goal
    // section) but never actually shipped until now.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        "[Date_Add(Date('2002-05-22 14:02:05'), -Second=15)->format('%Q %T')]|" +
            "[Date_Add(Date('2002-05-22 14:02:05'), -Day=15)->format('%Q')]|" +
            "[Date_Add(Date('2002-05-22 14:02:05'), -Week=15)->format('%Q')]|" +
            "[Date_Add(Date('2002-05-22 14:02:05'), -Month=6)->format('%Q')]|" +
            "[Date_Add(Date('2002-05-22 14:02:05'), -Year=1)->format('%Q')]|" +
            "[Date_Subtract(Date('2001-05-22 14:02:05'), -Second=15)->format('%Q %T')]",
        context: &context
    )
    let parts = output.components(separatedBy: "|")
    #expect(parts[0] == "2002-05-22 14:02:20")
    #expect(parts[1] == "2002-06-06")
    #expect(parts[2] == "2002-09-04")
    #expect(parts[3] == "2002-11-22")
    #expect(parts[4] == "2003-05-22")
    #expect(parts[5] == "2001-05-22 14:01:50")
}

@Test func dateAddMemberMutatesTheInvocantInPlaceAndReturnsVoid() async throws {
    // Ch. 29 Table 7: "[Date->Add] ... do not directly output values, but
    // can be used to change the values of variables that contain date...
    // data types" — unlike the free-tag form, this mutates in place.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        "[var(d = Date('2002-05-22'))][$d->add(-Week=1)]after=[$d->format('%Q')]",
        context: &context
    )
    // ->add itself prints nothing (returns void); the mutation is only
    // visible through the variable afterward.
    #expect(output == "after=2002-05-29")
}

@Test func dateSubtractMemberMutatesTheInvocantInPlace() async throws {
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        "[var(d = Date('2002-05-22'))][$d->subtract(-Day=1)]after=[$d->format('%Q')]",
        context: &context
    )
    #expect(output == "after=2002-05-21")
}

@Test func dateAddDoesNotAliasAnotherVariableThatWasAssignedFromTheSameDate() async throws {
    // Real bug: an earlier version of `->Add`/`->Subtract` mutated the
    // receiver's own `LassoObjectInstance` fields directly (reasoning
    // that `date` objects are class-backed, so no write-back was
    // needed) — but plain variable assignment in this interpreter copies
    // the `LassoValue.object` enum case, not the class instance it
    // wraps, so `var(d2 = $d1)` leaves both variables pointing at the
    // SAME instance. Mutating it in place made `$d1->add(...)` silently
    // also change `$d2`. Real Lasso's own Language Guide "References"
    // section confirms plain assignment is supposed to copy — aliasing
    // is only ever the explicit, opt-in `[Reference]`/`@` mechanism, not
    // the default. Fixed by never mutating the receiver: `->Add`/
    // `->Subtract` now build a genuinely new date object and rely on
    // `Evaluator.evaluateStatement`'s existing self-mutating write-back
    // to reassign only the calling variable, exactly like `Array->Insert`
    // already does for `.array`.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        """
        [var(d1 = Date('2002-05-22'))]
        [var(d2 = $d1)]
        [$d1->add(-Day=1)]
        d1=[$d1->format('%Q')]|d2=[$d2->format('%Q')]
        """,
        context: &context
    )
    #expect(output.contains("d1=2002-05-23"))
    #expect(output.contains("d2=2002-05-22"))
}

@Test func mathArithmeticTagsMatchTheLanguageGuidesOwnWorkedExamples() async throws {
    // Lasso 8.5 Language Guide Ch. 28 Table 10, confirmed by reading the
    // PDF directly (including the visual page render, since the raw text
    // extraction alone looked suspicious around Math_Div -- see the
    // dedicated math_div test below). None of Math_Add/Sub/Mult/Div/Max/
    // Min/Mod existed at all before this -- only the bare arithmetic
    // symbols (+/-/*// /%) worked.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        "[Math_Add(1, 2, 3, 4, 5)]|" +
            "[Math_Add(1.0, 100.0)]|" +
            "[Math_Sub(10, 5)]|" +
            "[Math_Max(100, 200)]|" +
            "[Math_Min(100, 200)]|" +
            "[Math_Mod(10, 3)]|" +
            "[Math_Mult(3, 4)]",
        context: &context
    )
    let parts = output.components(separatedBy: "|")
    #expect(parts[0] == "15")
    #expect(parts[1] == "101.0")
    #expect(parts[2] == "5")
    #expect(parts[3] == "200")
    #expect(parts[4] == "100")
    #expect(parts[5] == "1")
    #expect(parts[6] == "12")
}

@Test func mathDivFollowsTheDocumentedIntegerDecimalCoercionRuleNotTheGuidesOwnOutlierExamples() async throws {
    // Ch. 28 p.369's own clean, internally-consistent example:
    // "[Math_Div: 1, 8] -> 0" (all-integer parameters truncate toward
    // the integer result -- 0.125 rounds down to zero when cast to an
    // integer) and "[Math_Div: 1.0, 8] -> 0.125000" (a decimal parameter
    // keeps full precision). Deliberately does NOT match the Guide's own
    // very next page's two-parameter examples ("[Math_Div: 10, 9] -> 11",
    // "[Math_Div: 10, 8.0] -> 12.5") -- those don't correspond to any
    // sensible division of their stated inputs (10/9 != 11, 10/8.0 !=
    // 12.5) and are almost certainly a real transcription defect in the
    // PDF itself, verified by reading the actual page image, not just
    // pdftotext's linearized text (this project has already confirmed at
    // least one other verbatim doc defect: Valid_CreditCard's "ROT-13"
    // mislabeling).
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        "[Math_Div(1, 8)]|[Math_Div(1.0, 8)]",
        context: &context
    )
    let parts = output.components(separatedBy: "|")
    #expect(parts[0] == "0")
    #expect(parts[1] == "0.125")
}

@Test func mathCeilFloorRIntAlwaysReturnIntegersRegardlessOfInputType() async throws {
    // Ch. 28 "Rounding Numbers", confirmed worked examples.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        "[Math_RInt(37.6)]|[Math_Floor(37.6)]|[Math_Ceil(37.6)]",
        context: &context
    )
    #expect(output == "38|37|38")
}

@Test func mathRoundSupportsBothTheDecimalPrecisionAndIntegerMultipleForms() async throws {
    // Ch. 28 "Rounding Numbers" — two documented forms sharing one
    // formula: a decimal precision argument (e.g. 0.0001) rounds to that
    // many decimal places; an integer precision argument (e.g. 1000)
    // rounds to the nearest multiple of it. Confirmed by all seven of
    // the Guide's own worked examples across both forms.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        "[Math_Round(3.1415926, 0.0001)]|" +
            "[Math_Round(3.1415926, 0.001)]|" +
            "[Math_Round(3.1415926, 0.01)]|" +
            "[Math_Round(3.1415926, 0.1)]|" +
            "[Math_Round(1463, 1000)]|" +
            "[Math_Round(1463, 100)]|" +
            "[Math_Round(1463, 10)]",
        context: &context
    )
    let parts = output.components(separatedBy: "|")
    #expect(parts[0] == "3.1416")
    #expect(parts[1] == "3.142")
    #expect(parts[2] == "3.14")
    #expect(parts[3] == "3.1")
    #expect(parts[4] == "1000")
    #expect(parts[5] == "1500")
    #expect(parts[6] == "1460")
}

@Test func mathRandomRespectsMinMaxAndTheDocumentedExclusiveIntegerUpperBound() async throws {
    // Ch. 28 "Random Numbers": "-Max: Maximum value to be returned. For
    // integer results should be one greater than maximum desired value"
    // -- the real range is [min, max). Confirmed via the Guide's own
    // worked example ("a random number between 1 and 99" from
    // -Min=1, -Max=100).
    var context = LassoContext()
    for _ in 0..<50 {
        let output = try await LassoRenderer().render(
            "[Math_Random(-Min=1, -Max=100)]",
            context: &context
        )
        let value = Int(output) ?? -1
        #expect(value >= 1 && value <= 99)
    }
}

@Test func mathRandomReturnsADecimalWhenMinOrMaxIsADecimal() async throws {
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        "[Math_Random(-Min=0.0, -Max=1.0)]",
        context: &context
    )
    let value = Double(output) ?? -1
    #expect(value >= 0.0 && value < 1.0)
    #expect(output.contains("."))
}

@Test func mathRandomHexReturnsHexadecimalNotation() async throws {
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        "[Math_Random(-Min=16, -Max=256, -Hex)]",
        context: &context
    )
    #expect(output.count == 2)
    #expect(output.allSatisfy { $0.isHexDigit })
}

@Test func mathSqrtAndMathPowMatchTheLanguageGuidesOwnWorkedExamples() async throws {
    // Ch. 28 "Trigonometry and Advanced Math" — confirmed worked
    // examples: `Math_Pow(3, 3)` -> `27` (integer result for integer
    // inputs), `Math_Sqrt(100.0)` -> `10.0`.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        "[Math_Pow(3, 3)]|[Math_Sqrt(100.0)]",
        context: &context
    )
    #expect(output == "27|10.0")
}

@Test func mathAbsPreservesTheInvocantsIntegerOrDecimalType() async throws {
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        "[Math_Abs(-5)]|[Math_Abs(-5.5)]",
        context: &context
    )
    #expect(output == "5|5.5")
}

@Test func unaryMinusOnAWholeNumberPreservesIntegerTypeNotAlwaysDecimal() async throws {
    // Real bug caught by architect review of the Math_* work: `Evaluator.unary`'s
    // "-"/"+" cases previously returned `.decimal` unconditionally,
    // regardless of the operand's own type -- the number lexer never
    // consumes a leading sign, so every negative literal parses as this
    // unary operator applied to a plain number token, not as part of the
    // literal itself. That silently downgraded `-5` from an integer to a
    // decimal purely because of how its sign was written, contradicting
    // the documented "if all the parameters are integers the result will
    // be an integer" rule the new Math_* family depends on --
    // `Math_Add(-5, 3)` printed `-2.0`, not `-2`. Fixed by mirroring
    // `numeric(_:_:_:)`'s own established whole-number-result convention.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        "[Math_Add(-5, 3)]|[-5]|[-5.5]|[+5]",
        context: &context
    )
    #expect(output == "-2|-5|-5.5|5")
}

// lassoguide.com "Byte Streams" — `bytes(...)->decodeBase64`/
// `->encodeBase64`/`->encodeUrl` are the only three members implemented,
// matching the only three real corpus ever calls (confirmed by grepping
// every `bytes(` call site across the site). Corpus shape:
// pages/account.page.lasso's `string((bytes(action_param('site_to_view'))
// ->decodebase64)))`, and account_info_static.lasso's
// `bytes(string(field('cust_id')))->encodebase64->encodeurl`.
@Test func bytesConstructorEncodesAStringAsUTF8BytesAndOutputsItsRawContent() async throws {
    var context = LassoContext()
    let output = try await LassoRenderer().render("[bytes('hello')]", context: &context)
    #expect(output == "hello")
}

@Test func bytesWithNoArgumentIsEmpty() async throws {
    var context = LassoContext()
    let output = try await LassoRenderer().render("[bytes]", context: &context)
    #expect(output == "")
}

@Test func bytesEncodeBase64ThenDecodeBase64RoundTripsTheOriginalString() async throws {
    // account_info_static.lasso's exact shape:
    // bytes(string(field('cust_id')))->encodebase64->encodeurl generates
    // the URL; account.page.lasso's bytes(action_param(...))->decodebase64
    // reads it back once the browser/HTTP layer has already URL-decoded
    // the query parameter -- only the base64 layer needs an explicit
    // decode step here, matching that real round trip.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        "[string(bytes(bytes('12345')->encodebase64)->decodebase64)]",
        context: &context
    )
    #expect(output == "12345")
}

@Test func bytesDecodeBase64OnAKnownBase64StringProducesTheOriginalText() async throws {
    // "MTIzNDU=" is the standard base64 encoding of "12345" — computed
    // independently via Python's stdlib base64, not hand-derived.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        "[string(bytes('MTIzNDU=')->decodebase64)]",
        context: &context
    )
    #expect(output == "12345")
}

@Test func bytesDecodeBase64OnInvalidInputReturnsAnEmptyBytesObjectRatherThanThrowing() async throws {
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        "[bytes('not valid base64!!!')->decodebase64]",
        context: &context
    )
    #expect(output == "")
}

@Test func bytesConstructorCopiesAnExistingBytesObjectRatherThanStringifyingIt() async throws {
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        "[bytes(bytes('hello'))]",
        context: &context
    )
    #expect(output == "hello")
}

@Test func bytesEncodeUrlPercentEncodesIllegalUrlCharacters() async throws {
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        "[bytes('a b+c')->encodeurl]",
        context: &context
    )
    #expect(output.contains(" ") == false)
}

@Test func rendersIncludesRequestSessionAndInlineFrames() async throws {
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
        private var startedNames: Set<String> = []
        func start(session name: String, call: LassoSessionStartCall) async -> LassoSessionStartResult? {
            let isNew = startedNames.contains(name) == false
            startedNames.insert(name)
            return LassoSessionStartResult(sessionID: "fake-\(name)", isNew: isNew)
        }
        func id(session name: String) -> String? { startedNames.contains(name) ? "fake-\(name)" : nil }
        func restoredValue(for varName: String, session name: String) -> LassoValue? { nil }
        func persist(_ value: LassoValue, for varName: String, session name: String) {}
        func removeVar(_ varName: String, session name: String) {}
        func end(session name: String) { startedNames.remove(name) }
        func abort(session name: String) {}
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

    let includeOutput = try await LassoRenderer().render("[include:'partials/header.lasso']", context: &context)
    #expect(includeOutput == "<h1>Catalog</h1>")

    let requestOutput = try await LassoRenderer().render(
        "[web_request->param('term')]|[web_request->header('host')]|[web_request->httpHost]|[cookie:'sid']",
        context: &context
    )
    #expect(requestOutput == "clogs|example.test|example.test|abc123")

    let sessionOutput = try await LassoRenderer().render(
        "[session_start('cart')][var(cartvalue = 'open')][session_addvar('cart','cartvalue')][cartvalue]",
        context: &context
    )
    #expect(sessionOutput == "open")

    let inlineSource = "[inline:-search,-database='demo',-table='items',-op='eq',-active='yes',-sortfield='name']" +
        "[records][field:'name']:[field:'qty'];[/records]([found_count])[/inline]"
    let inlineOutput = try await LassoRenderer().render(inlineSource, context: &context)
    #expect(inlineOutput == "Alpha:2;Beta:3;(2)")
}

@Test func parsesAndRendersLassoScriptInlineJSON() async throws {
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
        func executeInline(arguments: [EvaluatedArgument], context: LassoContext) async throws -> LassoInlineFrame {
            let request = try LassoInlineRequest(arguments: arguments)
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
    let output = try await LassoRenderer().render(scriptInline, context: &context)
    #expect(
        output == "[{\"preview\":\"one.jpg\",\"catalog_sku\":\"SKU-1\"}]" ||
            output == "[{\"catalog_sku\":\"SKU-1\",\"preview\":\"one.jpg\"}]"
    )
}

@Test func inlineBareColonCallWithNoParensParsesAndExecutesInsideLassoScript() async throws {
    // Real corpus shape (Documentation/outstanding-compatibility-project-plans.md
    // item 4, e.g. importscripts/ca_web.lasso): Lasso 8's bare colon-call
    // convention with NO enclosing parens at all — `inline: -database=...,
    // -sql=...; ... /inline;` — distinct from the already-working
    // parenthesized `inline(...)` form covered by
    // parsesAndRendersLassoScriptInlineJSON above. Before adding "inline"
    // to ScriptBodyParser.bareBlockNames, this fell through to an ordinary
    // colon-call expression statement and threw unknownFunction("inline")
    // at evaluation time, never reaching the block/frame machinery at all.
    let scriptInline = """
    <?LassoScript
    inline:
        -database='catalog_mysql',
        -table='skus',
        -sql='TRUNCATE TABLE skus;';
        action_statement;
    /inline;
    ?>
    """

    let document = LassoParser().parse(scriptInline)
    #expect(document.diagnostics.isEmpty)
    guard case let .block(name, arguments, _, _, _, _) = document.nodes.first else {
        Issue.record("Expected the bare colon-call to parse as a real block, not fall through to an ordinary call expression")
        return
    }
    #expect(name.lowercased() == "inline")
    #expect(arguments.count == 3)

    struct InlineProvider: LassoInlineProvider {
        func executeInline(arguments: [EvaluatedArgument], context: LassoContext) async throws -> LassoInlineFrame {
            let request = try LassoInlineRequest(arguments: arguments)
            #expect(request.database == "catalog_mysql")
            #expect(request.table == "skus")
            #expect(request.sql == "TRUNCATE TABLE skus;")
            return LassoInlineFrame(rows: [], actionStatement: "SQL")
        }
    }

    var context = LassoContext(inlineProvider: InlineProvider())
    let output = try await LassoRenderer().render(scriptInline, context: &context)
    #expect(output.trimmingCharacters(in: .whitespacesAndNewlines) == "SQL")
}

@Test func inlineBareColonCallSqlArgumentConcatenatedAcrossLinesWithTrailingPlus() async throws {
    // Real corpus shape (importscripts/ca_web.lasso and siblings): a -SQL
    // argument built from several single-quoted fragments joined by `+`,
    // each fragment on its own line with a trailing `+` — a third
    // real trailing-character continuation case (alongside `,` and the
    // block-opener's own `:`) found `grep`-counting every line ending
    // inside the real inline blocks. Confirms ScriptBodyParser.readStatement's
    // line-continuation fix isn't limited to comma-separated arguments.
    let scriptInline = """
    <?LassoScript
    inline:
        -database='catalog_mysql',
        -table='skus',
        -sql='TRUNCATE TABLE ' +
            'skus;';
        action_statement;
    /inline;
    ?>
    """

    struct InlineProvider: LassoInlineProvider {
        func executeInline(arguments: [EvaluatedArgument], context: LassoContext) async throws -> LassoInlineFrame {
            let request = try LassoInlineRequest(arguments: arguments)
            #expect(request.sql == "TRUNCATE TABLE skus;")
            return LassoInlineFrame(rows: [], actionStatement: "SQL")
        }
    }

    var context = LassoContext(inlineProvider: InlineProvider())
    let output = try await LassoRenderer().render(scriptInline, context: &context)
    #expect(output.trimmingCharacters(in: .whitespacesAndNewlines) == "SQL")
}

@Test func inlineColonWithParensStillWorksAlongsideTheBareColonCallFix() async throws {
    // Regression guard: `inline:(...)` (colon immediately followed by
    // parens, matching the already-fixed `if:(condition)` shape) is a
    // different branch (ScriptBodyParser.parseBlockOpening, not
    // emitStatement's bareBlockNames) and must keep working unchanged.
    let scriptInline = """
    <?LassoScript
    inline:(-database='catalog_mysql', -table='skus', -sql='SELECT 1;');
        action_statement;
    /inline;
    ?>
    """

    struct InlineProvider: LassoInlineProvider {
        func executeInline(arguments: [EvaluatedArgument], context: LassoContext) async throws -> LassoInlineFrame {
            LassoInlineFrame(rows: [], actionStatement: "SQL")
        }
    }

    var context = LassoContext(inlineProvider: InlineProvider())
    let output = try await LassoRenderer().render(scriptInline, context: &context)
    #expect(output.trimmingCharacters(in: .whitespacesAndNewlines) == "SQL")
}

@Test func inlineBareColonCallArgumentFoldsJuxtaposedStringConcatenation() async throws {
    // Was a deliberately-deferred gap (found live-verifying the
    // bareBlockNames/line-continuation fixes above against the real corpus
    // — components/inSite/filtered_links.inc, the one file, of 15
    // originally failing on unknownFunction("inline"), that still failed
    // after those fixes), now fixed by `ExpressionParser.parseJuxtaposedValue()`.
    // Lasso 8's operator-less string/variable juxtaposition concatenation
    // (Language Guide Ch. 22, "Miscellaneous Shortcuts": `'text' #localVar
    // 'more text'`, no `+` between them — confirmed via the Lasso 8.5
    // Language Guide PDF, not just corpus inference) previously broke
    // specifically *inside* an argument's value: `parseArguments` called
    // `parseExpression()` exactly once per value, so the leading string
    // was captured but `#cat_master` and the trailing string spilled out
    // as extra top-level expressions — which made
    // `ScriptBodyParser.emitStatement` see more than one top-level
    // expression and fall back to `.code(...)` instead of the
    // bareBlockNames `.tag(...)` promotion, so `inline` was evaluated as
    // an ordinary (unregistered) function call.
    let scriptInline = """
    <?LassoScript
    local: 'cat_master' = 'cat_master value';
    inline: -database='catalog_mysql',
        -sql='SELECT * FROM categories WHERE cat = "' #cat_master '"';
        action_statement;
    /inline;
    ?>
    """

    let document = LassoParser().parse(scriptInline)
    #expect(document.diagnostics.isEmpty)
    guard case let .block(name, arguments, _, _, _, _) = document.nodes.dropFirst().first else {
        Issue.record("Expected the juxtaposed -sql value to still fold into one real inline block")
        return
    }
    #expect(name.lowercased() == "inline")
    #expect(arguments.count == 2)

    struct InlineProvider: LassoInlineProvider {
        func executeInline(arguments: [EvaluatedArgument], context: LassoContext) async throws -> LassoInlineFrame {
            let request = try LassoInlineRequest(arguments: arguments)
            #expect(request.sql == "SELECT * FROM categories WHERE cat = \"cat_master value\"")
            return LassoInlineFrame(rows: [], actionStatement: "SQL")
        }
    }

    var context = LassoContext(inlineProvider: InlineProvider())
    let output = try await LassoRenderer().render(scriptInline, context: &context)
    #expect(output.trimmingCharacters(in: .whitespacesAndNewlines) == "SQL")
}

@Test func juxtaposedConcatenationFoldsInAnyParenCallArgumentNotJustInline() async throws {
    // The fix lives in `ExpressionParser.parseArguments` (shared by every
    // paren-call and bare-colon-call), not bolted onto "inline"
    // specifically — proven here with a plain native-function paren call,
    // matching the Lasso 8.5 Language Guide's own general example
    // (`['Showing ' (Shown_Count) ' records of ' (Found_Count) ' found.']`).
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        "[String('a' 'b' 'c', -EncodeNone)]",
        context: &context
    )
    #expect(output == "abc")
}

@Test func trailingCommaBeforeCallerOwnedCloseParenDoesNotProduceUnknownExpression() async throws {
    // Real corpus: components/inSite/email_instances.inc's
    // `(Array: 'a', 'b', // commented-out element\n));` — a trailing
    // comma right before the `)` that belongs to the *outer* wrap, not to
    // `Array:`'s own (parenless) bare-colon-call argument list.
    // `parseArguments(closing: nil)` has no closing token of its own to
    // watch for, so after consuming that trailing comma it used to try
    // parsing `)` itself as the next argument's value — `parsePrefix`'s
    // catch-all turned that into `.unknown(")")`, surfacing as
    // `unsupportedExpression(")")` (this exact file, live-verified).
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        "[(Array: 'a', 'b', )->size]",
        context: &context
    )
    #expect(output == "2")
}

@Test func rendersCorpusFixtures() async throws {
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
        let output = try await LassoRenderer().render(source, context: &context)
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

    // An explicit, non-empty `allowedExtensions` still confines includes to
    // it — the mechanism itself still works when a caller opts in.
    let loader = try LassoFileSystemIncludeLoader(root: root, allowedExtensions: ["lasso"])
    #expect(try loader.loadInclude(path: "../shared.lasso", from: "pages/home.lasso") == "OK")
    #expect(throws: LassoFileSystemIncludeError.extensionNotAllowed("json")) {
        try loader.loadInclude(path: "secret.json", from: nil)
    }
    #expect(throws: LassoFileSystemIncludeError.pathOutsideRoot("../../outside.lasso")) {
        try loader.loadInclude(path: "../../outside.lasso", from: "pages/home.lasso")
    }
}

@Test func filesystemIncludeLoaderDefaultAllowsAnyExtensionButStillConfinesPaths() throws {
    // Real Lasso's `[Include(...)]` tag has no extension gate at all —
    // real corpus: pages/detail.page.lasso's
    // `[include('javascripts/magnify.js')]`, a real product detail page
    // include that failed outright with `extensionNotAllowed("js")` under
    // the previous restrictive default (`lasso, inc, html, htm, txt`
    // only). Path confinement (not extension) is the real security
    // boundary and must still apply with no `allowedExtensions` override.
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("lasso-loader-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try "console.log('hi')".write(to: root.appendingPathComponent("magnify.js"), atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: root) }

    let loader = try LassoFileSystemIncludeLoader(root: root)
    #expect(try loader.loadInclude(path: "magnify.js", from: nil) == "console.log('hi')")
    #expect(throws: LassoFileSystemIncludeError.pathOutsideRoot("../../outside.js")) {
        try loader.loadInclude(path: "../../outside.js", from: "pages/home.lasso")
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

@Test func startupDirectoryLoadsMatchingExtensionsAndSkipsOthers() async throws {
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
    let result = await loadLassoStartupDirectory(
        at: root,
        allowedExtensions: ["lasso", "inc"],
        tagRegistry: registry
    )

    #expect(Set(result.loadedFiles) == ["a.inc", "b.lasso"])
    #expect(result.failedFiles.isEmpty)
    #expect(registry.containsTag(named: "greet"))
    #expect(registry.containsTag(named: "farewell"))
}

@Test func startupDirectoryContinuesPastAFailingFileAndReportsIt() async throws {
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
    let result = await loadLassoStartupDirectory(
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

@Test func startupDirectoryHandlesMissingDirectoryGracefully() async {
    let missing = FileManager.default.temporaryDirectory
        .appendingPathComponent("lasso-startup-does-not-exist-\(UUID().uuidString)")
    let registry = LassoTagRegistry()

    let result = await loadLassoStartupDirectory(
        at: missing,
        allowedExtensions: ["lasso", "inc"],
        tagRegistry: registry
    )

    #expect(result.loadedFiles.isEmpty)
    #expect(result.failedFiles.count == 1)
    #expect(result.failedFiles.first?.error == "not a directory or does not exist")
}

@Test func startupDirectoryTagsAreVisibleToLaterContextsSharingTheRegistry() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("lasso-startup-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    try "<?lassoscript define shout(msg = void) => { return(#msg + '!') } ?>".write(
        to: root.appendingPathComponent("setup.inc"), atomically: true, encoding: .utf8
    )

    let registry = LassoTagRegistry()
    let result = await loadLassoStartupDirectory(at: root, allowedExtensions: ["inc"], tagRegistry: registry)
    #expect(result.failedFiles.isEmpty)

    var pageContext = LassoContext(tagRegistry: registry)
    let output = try await LassoRenderer().render(
        "[shout(-msg='hello')]",
        context: &pageContext
    )
    #expect(output == "hello!")
}

@Test func dynamicInlineProviderMapsDatasourceForPerfectCRUDExecutor() async throws {
    struct Executor: LassoDynamicQueryExecutor {
        func execute(_ request: LassoInlineRequest) async throws -> LassoInlineFrame {
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
    let output = try await LassoRenderer().render(
        "[inline(-database='catalog_mysql',-table='skus',-findall)][records][field('mfr_style_no')][/records][/inline]",
        context: &context
    )
    #expect(output == "247")
}

@Test func perfectCRUDExecutorMapsSearchWithoutApplicationSpecificAPI() async throws {
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
    let output = try await LassoRenderer().render(
        "[inline(-database='catalog_mysql',-table='skus',-op='cn','store_id'=$product_subset," +
            "-op='cn','featured'='seasonal_sale',-ReturnField='mfr_style_no'," +
            "-ReturnField='color',-search)][records][field('mfr_style_no')]:" +
            "[field('color')];[/records][/inline]",
        context: &context
    )
    #expect(output == "247:Black;701:Navy;")
}

@Test func perfectCRUDExecutorSuppliesASentinelLimitWhenSkipRecordsHasNoMaxrecords() async throws {
    // Real Lasso/FileMaker CWP treats `-SkipRecords` with no `-Maxrecords`
    // as "skip N, return everything else" — no upper bound. Real corpus:
    // pages/advanced_search.page.lasso's top-category query,
    // `-SkipRecords=0` with no `-Maxrecords` at all. `DynamicQuery` (the
    // sibling Perfect-CRUD package) requires a non-nil `limit` whenever
    // `offset` is set — the previous code left `limit` nil whenever no
    // server-side cap was configured, regardless of whether an offset was
    // present, so this real query threw "Dynamic query offset requires a
    // limit" on every request, silently zeroing the "Show Only <category>"
    // checkbox list on the real Advanced Search page.
    final class QueryRecorder: @unchecked Sendable {
        private(set) var queries: [DynamicQuery] = []
        func record(_ query: DynamicQuery) { queries.append(query) }
    }
    let recorder = QueryRecorder()
    let executor = PerfectCRUDLassoExecutor(
        capabilities: { _ in .readOnly },
        queryHandler: { _, query in
            recorder.record(query)
            return DynamicResult(rows: [], statement: "SELECT ...")
        }
    )
    let provider = LassoDynamicInlineProvider(executor: executor, datasourceAliases: ["catalog_mysql": "catalog"])
    var context = LassoContext(inlineProvider: provider)

    _ = try await LassoRenderer().render(
        "[inline(-database='catalog_mysql',-table='lc_web',-op='eq','parent_id'='0',-SkipRecords=0,-search)][/inline]",
        context: &context
    )

    let seenQueries = recorder.queries
    #expect(seenQueries.count == 1)
    #expect(seenQueries[0].offset == 0)
    #expect(seenQueries[0].limit != nil)
}

@Test func fieldAfterANestedUpdateInlineStillReadsTheOuterSearchRow() async throws {
    // Reproduces pages/lost_password.page.lasso's real shape: an outer
    // -search inline finds a row (with no [records] loop — no `field()`
    // read is ever inside one), then a SEPARATE, NESTED -update inline
    // runs and closes, then `field('password')` reads a column from the
    // OUTER search's row. Investigated as a suspected `field()`-missing-
    // request-param-fallback bug (per a corpus-crawl finding of
    // "Encrypt_HMAC requires -Token" failures on this exact call), but
    // this test proves the inline-frame stack (push/popInlineFrame) is
    // already correct: the nested inline's own frame is popped before
    // `field()` runs, restoring the outer frame, whose `rows.first` still
    // has the real value. No interpreter bug found here — most likely
    // the crawl's failure was itself an environment artifact (no live
    // datasource wired for that crawl run, matching this session's
    // broader finding that the file-by-file crawler needs real context
    // to produce trustworthy signal).
    var context = LassoContext(inlineProvider: LassoInMemoryInlineProvider(tables: [
        "cm_web": [
            LassoDataRow(["email": .string("user@example.com"), "password": .string("realpass123")], keyValue: .integer(1)),
        ],
    ]))
    let output = try await LassoRenderer().render(
        "[local(new_email::string = 'user@example.com')]" +
        "[inline(-database='scrubs_data',-table='CM_web',-eq,'email'=#new_email,-search)]" +
        "[local(recid = keyfield_value)]" +
        "[if(Found_Count > 0)]" +
        "[inline(-database='scrubs_data',-table='CM_web',-keyvalue=#recid,'pass_reset'=12345,-update)][/inline]" +
        "password=[field('password')]" +
        "[else]not-found[/if]" +
        "[/inline]",
        context: &context
    )
    #expect(output == "password=realpass123")
}

@Test func inlineRequestSplitsFieldAssignmentsFromSearchCriteria() throws {
    // Documentation/inline-write-raw-sql-plan.md's core design point: in
    // -Add/-Update, unlabeled name/value arguments are values to write, not
    // search predicates -- reusing `criteria` for those actions would
    // misinterpret assignment values as WHERE-clause filters.
    let add = try LassoInlineRequest(arguments: [
        EvaluatedArgument(label: "database", value: .string("catalog")),
        EvaluatedArgument(label: "table", value: .string("skus")),
        EvaluatedArgument(label: "add", value: .boolean(true)),
        EvaluatedArgument(label: "color", value: .string("red")),
        EvaluatedArgument(label: "size", value: .string("M")),
    ])
    #expect(add.action == .add)
    #expect(add.fieldAssignments == [
        LassoInlineAssignment(field: "color", value: .string("red")),
        LassoInlineAssignment(field: "size", value: .string("M")),
    ])
    #expect(add.writeCriteria == [])

    let update = try LassoInlineRequest(arguments: [
        EvaluatedArgument(label: "database", value: .string("catalog")),
        EvaluatedArgument(label: "table", value: .string("skus")),
        EvaluatedArgument(label: "update", value: .boolean(true)),
        EvaluatedArgument(label: "keyfield", value: .string("id")),
        EvaluatedArgument(label: "keyvalue", value: .integer(42)),
        EvaluatedArgument(label: "color", value: .string("blue")),
    ])
    #expect(update.action == .update)
    #expect(update.fieldAssignments == [LassoInlineAssignment(field: "color", value: .string("blue"))])
    #expect(update.writeCriteria == [LassoInlineCriterion(field: "id", operation: "eq", value: .integer(42))])

    let delete = try LassoInlineRequest(arguments: [
        EvaluatedArgument(label: "database", value: .string("catalog")),
        EvaluatedArgument(label: "table", value: .string("skus")),
        EvaluatedArgument(label: "delete", value: .boolean(true)),
        EvaluatedArgument(label: "keyfield", value: .string("id")),
        EvaluatedArgument(label: "keyvalue", value: .integer(42)),
        // A stray field/value argument on a delete is not an assignment --
        // real Lasso 8.5 documents -Delete's target as coming from
        // -KeyField/-KeyValue only.
        EvaluatedArgument(label: "color", value: .string("ignored")),
    ])
    #expect(delete.action == .delete)
    #expect(delete.fieldAssignments == [])
    #expect(delete.writeCriteria == [LassoInlineCriterion(field: "id", operation: "eq", value: .integer(42))])
}

@Test func inlineRequestSplitsCriteriaIntoNotDelimitedGroups() throws {
    // Real corpus shape (pages/order_history.page.lasso,
    // pages/order_reporting.page.lasso): -op='Eq', 'cust_id'=X, -Not,
    // -op='Eq', 'status'='unchecked' -- one bare -Not splits the search
    // into "cust_id = X" (not negated) and "status = 'unchecked'"
    // (negated). Real Lasso's FileMaker connector documents -Not as
    // negating the whole compound query group that follows it.
    let request = try LassoInlineRequest(arguments: [
        EvaluatedArgument(label: "database", value: .string("fm_catalog")),
        EvaluatedArgument(label: "table", value: .string("storefront")),
        EvaluatedArgument(label: "op", value: .string("Eq")),
        EvaluatedArgument(label: "cust_id", value: .integer(7)),
        EvaluatedArgument(label: "not", value: .boolean(true)),
        EvaluatedArgument(label: "op", value: .string("Eq")),
        EvaluatedArgument(label: "status", value: .string("unchecked")),
        EvaluatedArgument(label: "search", value: .boolean(true)),
    ])
    #expect(request.criteriaGroups == [
        LassoInlineCriteriaGroup(
            criteria: [LassoInlineCriterion(field: "cust_id", operation: "Eq", value: .integer(7))],
            negated: false
        ),
        LassoInlineCriteriaGroup(
            criteria: [LassoInlineCriterion(field: "status", operation: "Eq", value: .string("unchecked"))],
            negated: true
        ),
    ])

    // Regression for the fix: a bare -Not must not become a bogus
    // "not" field criterion in the flat, negation-oblivious `criteria`
    // array MySQL's executor still relies on, and must not shift the
    // -Op positional alignment for the criterion after it.
    #expect(request.criteria == [
        LassoInlineCriterion(field: "cust_id", operation: "Eq", value: .integer(7)),
        LassoInlineCriterion(field: "status", operation: "Eq", value: .string("unchecked")),
    ])
}

@Test func inlineRequestWithNoNotProducesOneNonNegatedGroupMatchingFlatCriteria() throws {
    let request = try LassoInlineRequest(arguments: [
        EvaluatedArgument(label: "database", value: .string("catalog")),
        EvaluatedArgument(label: "table", value: .string("skus")),
        EvaluatedArgument(label: "color", value: .string("red")),
        EvaluatedArgument(label: "search", value: .boolean(true)),
    ])
    #expect(request.criteriaGroups.count == 1)
    #expect(request.criteriaGroups.first?.negated == false)
    #expect(request.criteriaGroups.first?.criteria == request.criteria)
}

@Test func keyfieldValueReadsLassoDataRowKeyValueAndIsNullWhenAbsent() async throws {
    var context = LassoContext(inlineProvider: LassoInMemoryInlineProvider(tables: [
        "storefront": [LassoDataRow(["status": .string("unchecked")], keyValue: .integer(101))],
    ]))
    let output = try await LassoRenderer().render(
        "[inline(-database='catalog',-table='storefront',-search)][records][keyfield_value][/records][/inline]",
        context: &context
    )
    #expect(output == "101")

    // No current row (outside any inline/records) -- .null, not a crash.
    var emptyContext = LassoContext()
    let emptyOutput = try await LassoRenderer().render("[keyfield_value]", context: &emptyContext)
    #expect(emptyOutput == "")
}

// MARK: - PerfectFileMakerLassoExecutor

/// Thrown by test `queryHandler` stubs after capturing the `FMPQuery` they
/// were called with, so tests can inspect the mapped query (via its public
/// `queryString`) without needing a real `FMPResultSet` -- `FMPResultSet`/
/// `FMPRecord` have no public initializer anywhere in the upstream
/// `Perfect-FileMaker` library (their only inits parse a real XML
/// response), so no test in this file can construct a "successful" result
/// on its own. Full read-path (row/field mapping) coverage instead comes
/// from live-verifying against the real FileMaker Server once credentials
/// are available -- see Documentation/lasso-perfect-server.md.
private enum TestFileMakerProbeError: Error {
    case stopAfterCapture
}

@Test func fileMakerExecutorThrowsMissingDatasourceWhenDatabaseAbsent() async throws {
    let executor = PerfectFileMakerLassoExecutor { _, _, _ in
        Issue.record("queryHandler should not be called before -database is validated")
        throw TestFileMakerProbeError.stopAfterCapture
    }
    let request = try LassoInlineRequest(arguments: [
        EvaluatedArgument(label: "table", value: .string("storefront")),
        EvaluatedArgument(label: "findall", value: .boolean(true)),
    ])
    await #expect(throws: LassoFileMakerLassoError.missingDatasource) {
        try await executor.execute(request)
    }
}

@Test func fileMakerExecutorThrowsMissingTableWhenTableAbsent() async throws {
    let executor = PerfectFileMakerLassoExecutor { _, _, _ in
        Issue.record("queryHandler should not be called before -table is validated")
        throw TestFileMakerProbeError.stopAfterCapture
    }
    let request = try LassoInlineRequest(arguments: [
        EvaluatedArgument(label: "database", value: .string("fm_catalog")),
        EvaluatedArgument(label: "findall", value: .boolean(true)),
    ])
    await #expect(throws: LassoFileMakerLassoError.missingTable) {
        try await executor.execute(request)
    }
}

@Test func fileMakerExecutorThrowsUnsupportedActionForShow() async throws {
    let executor = PerfectFileMakerLassoExecutor { _, _, _ in
        Issue.record("queryHandler should not be called for an unsupported action")
        throw TestFileMakerProbeError.stopAfterCapture
    }
    let request = try LassoInlineRequest(arguments: [
        EvaluatedArgument(label: "database", value: .string("fm_catalog")),
        EvaluatedArgument(label: "table", value: .string("storefront")),
        EvaluatedArgument(label: "show", value: .boolean(true)),
    ])
    await #expect(throws: LassoFileMakerLassoError.unsupportedAction(.show)) {
        try await executor.execute(request)
    }
}

@Test func fileMakerExecutorGatesAddUpdateDeleteBehindAllowWrites() async throws {
    let executor = PerfectFileMakerLassoExecutor(allowWrites: false) { _, _, _ in
        Issue.record("queryHandler should not be called while writes are disabled")
        throw TestFileMakerProbeError.stopAfterCapture
    }
    let base: [EvaluatedArgument] = [
        EvaluatedArgument(label: "database", value: .string("fm_catalog")),
        EvaluatedArgument(label: "table", value: .string("storefront")),
    ]

    let addFrame = try await executor.execute(try LassoInlineRequest(arguments: base + [
        EvaluatedArgument(label: "add", value: .boolean(true)),
        EvaluatedArgument(label: "status", value: .string("new")),
    ]))
    #expect(addFrame.error != .noError)
    #expect(addFrame.error.kind == "add")

    let updateFrame = try await executor.execute(try LassoInlineRequest(arguments: base + [
        EvaluatedArgument(label: "update", value: .boolean(true)),
        EvaluatedArgument(label: "keyfield", value: .string("")),
        EvaluatedArgument(label: "keyvalue", value: .integer(101)),
        EvaluatedArgument(label: "status", value: .string("checked")),
    ]))
    #expect(updateFrame.error != .noError)
    #expect(updateFrame.error.kind == "update")

    let deleteFrame = try await executor.execute(try LassoInlineRequest(arguments: base + [
        EvaluatedArgument(label: "delete", value: .boolean(true)),
        EvaluatedArgument(label: "keyfield", value: .string("")),
        EvaluatedArgument(label: "keyvalue", value: .integer(101)),
    ]))
    #expect(deleteFrame.error != .noError)
    #expect(deleteFrame.error.kind == "delete")
}

@Test func fileMakerExecutorThrowsMissingAssignmentsForUpdateWithNoFields() async throws {
    let executor = PerfectFileMakerLassoExecutor(allowWrites: true) { _, _, _ in
        Issue.record("queryHandler should not be called with no field assignments")
        throw TestFileMakerProbeError.stopAfterCapture
    }
    let base: [EvaluatedArgument] = [
        EvaluatedArgument(label: "database", value: .string("fm_catalog")),
        EvaluatedArgument(label: "table", value: .string("storefront")),
    ]

    await #expect(throws: LassoFileMakerLassoError.missingAssignments(.update)) {
        try await executor.execute(try LassoInlineRequest(arguments: base + [
            EvaluatedArgument(label: "update", value: .boolean(true)),
            EvaluatedArgument(label: "keyfield", value: .string("")),
            EvaluatedArgument(label: "keyvalue", value: .integer(101)),
        ]))
    }
}

@Test func fileMakerExecutorAllowsAddWithNoFieldsForAutoEntryOnlyTables() async throws {
    // Confirmed live 2026-07-18: includes/create_new_cust.include.lasso does
    // exactly this -- `-Add` with zero explicit field assignments, relying
    // entirely on FileMaker auto-entry (a serial cust_id) to populate the
    // new record. Real Lasso Server allows this; our executor used to throw
    // missingAssignments(.add) unconditionally, which this test guards
    // against regressing.
    final class Capture: @unchecked Sendable {
        var query: FMPQuery?
    }
    let capture = Capture()
    let executor = PerfectFileMakerLassoExecutor(allowWrites: true) { query, _, _ in
        capture.query = query
        throw TestFileMakerProbeError.stopAfterCapture
    }
    let request = try LassoInlineRequest(arguments: [
        EvaluatedArgument(label: "database", value: .string("fm_catalog")),
        EvaluatedArgument(label: "table", value: .string("storefront")),
        EvaluatedArgument(label: "add", value: .boolean(true)),
    ])
    _ = try? await executor.execute(request)
    let queryString = try #require(capture.query?.queryString)
    #expect(queryString.contains("-new"))
}

@Test func fileMakerExecutorReturnsRecoverableFrameWhenKeyValueMissingOrInvalid() async throws {
    let executor = PerfectFileMakerLassoExecutor(allowWrites: true) { _, _, _ in
        Issue.record("queryHandler should not be called with an invalid record id")
        throw TestFileMakerProbeError.stopAfterCapture
    }
    let base: [EvaluatedArgument] = [
        EvaluatedArgument(label: "database", value: .string("fm_catalog")),
        EvaluatedArgument(label: "table", value: .string("storefront")),
    ]

    // No -KeyValue at all (e.g. a tampered/missing hidden form field).
    let updateFrame = try await executor.execute(try LassoInlineRequest(arguments: base + [
        EvaluatedArgument(label: "update", value: .boolean(true)),
        EvaluatedArgument(label: "status", value: .string("checked")),
    ]))
    #expect(updateFrame.error != .noError)
    #expect(updateFrame.error.kind == "update")

    // A -KeyValue that isn't a valid record id.
    let deleteFrame = try await executor.execute(try LassoInlineRequest(arguments: base + [
        EvaluatedArgument(label: "delete", value: .boolean(true)),
        EvaluatedArgument(label: "keyfield", value: .string("")),
        EvaluatedArgument(label: "keyvalue", value: .string("not-a-number")),
    ]))
    #expect(deleteFrame.error != .noError)
    #expect(deleteFrame.error.kind == "delete")
}

@Test func fileMakerExecutorMapsSearchCriteriaAndOperatorsIntoFindQuery() async throws {
    final class Capture: @unchecked Sendable {
        var query: FMPQuery?
    }
    let capture = Capture()
    let executor = PerfectFileMakerLassoExecutor { query, _, _ in
        capture.query = query
        throw TestFileMakerProbeError.stopAfterCapture
    }
    let request = try LassoInlineRequest(arguments: [
        EvaluatedArgument(label: "database", value: .string("fm_catalog")),
        EvaluatedArgument(label: "table", value: .string("storefront")),
        EvaluatedArgument(label: "search", value: .boolean(true)),
        EvaluatedArgument(label: "op", value: .string("eq")),
        EvaluatedArgument(label: "status", value: .string("unchecked")),
    ])
    _ = try? await executor.execute(request)
    let queryString = try #require(capture.query?.queryString)
    #expect(queryString.contains("-db=fm_catalog"))
    #expect(queryString.contains("-lay=storefront"))
    #expect(queryString.contains("-findquery"))
    #expect(queryString.contains("status"))
    #expect(queryString.contains("unchecked"))
    // -Op='EQ' explicitly requested exact match -- FMPFieldOp.equal
    // renders "==value" with no trailing "*" (see FMPQueryField.valueWithOp
    // in the upstream Perfect-FileMaker source).
    #expect(queryString.contains("==unchecked&") || queryString.hasSuffix("==unchecked"))
    #expect(queryString.contains("==unchecked*") == false)
}

@Test func fileMakerExecutorDefaultsMissingOpToBeginsWithNotExactMatch() async throws {
    // Regression coverage for a real bug this session: a criterion with
    // no -Op at all must NOT silently become an exact-match (-EQ) search.
    // LassoInlineRequest's shared parsing (Providers.swift) represents
    // "no -Op supplied" as operation == nil (distinct from an explicit
    // -Op='EQ', which also lowercases to "eq") specifically so each
    // executor can apply its own connector-correct default; the FileMaker
    // connector's documented default is -BW (begins-with), NOT -EQ (real
    // Lasso 8.5 Ch. 11 Table 4) -- PerfectCRUDLassoExecutor's own -EQ
    // default is a distinct, correct-for-SQL-connectors default that must
    // NOT leak into this one.
    final class Capture: @unchecked Sendable {
        var query: FMPQuery?
    }
    let capture = Capture()
    let executor = PerfectFileMakerLassoExecutor { query, _, _ in
        capture.query = query
        throw TestFileMakerProbeError.stopAfterCapture
    }
    let request = try LassoInlineRequest(arguments: [
        EvaluatedArgument(label: "database", value: .string("fm_catalog")),
        EvaluatedArgument(label: "table", value: .string("storefront")),
        EvaluatedArgument(label: "search", value: .boolean(true)),
        EvaluatedArgument(label: "status", value: .string("unchecked")),
    ])
    _ = try? await executor.execute(request)
    let queryString = try #require(capture.query?.queryString)
    // FMPFieldOp.beginsWith renders "==value*" (trailing "*").
    #expect(queryString.contains("==unchecked*"))
}

@Test func fileMakerExecutorMapsNotGroupToNegatedCompoundQuerySegment() async throws {
    final class Capture: @unchecked Sendable {
        var query: FMPQuery?
    }
    let capture = Capture()
    let executor = PerfectFileMakerLassoExecutor { query, _, _ in
        capture.query = query
        throw TestFileMakerProbeError.stopAfterCapture
    }
    // Mirrors the real corpus shape: an unnegated group followed by a
    // bare -Not delimiting a second, negated group.
    let request = try LassoInlineRequest(arguments: [
        EvaluatedArgument(label: "database", value: .string("fm_catalog")),
        EvaluatedArgument(label: "table", value: .string("storefront")),
        EvaluatedArgument(label: "search", value: .boolean(true)),
        EvaluatedArgument(label: "cust_id", value: .integer(42)),
        EvaluatedArgument(label: "not", value: .boolean(true)),
        EvaluatedArgument(label: "status", value: .string("unchecked")),
    ])
    _ = try? await executor.execute(request)
    let queryString = try #require(capture.query?.queryString)
    // compoundQueryString renders a negated group as "!(qN)" -- see
    // FMPQuery.compoundQueryString in the upstream Perfect-FileMaker
    // source -- but the resurrected library's fmpEscaped encoder (a
    // deliberate query-injection fix: the old PerfectLib encoder left
    // `& = ! ( ) * ;` unescaped) now percent-encodes the whole compound
    // query segment, including its structural "!"/"("/")" characters, not
    // just field values. "!(q2)" -> "%21%28q2%29", "(q1)" -> "%28q1%29".
    #expect(queryString.contains("%21%28q2%29"))
    #expect(queryString.contains("%28q1%29"))
}

@Test func fileMakerExecutorThrowsUnsupportedComparisonForUnknownOperator() async throws {
    let executor = PerfectFileMakerLassoExecutor { _, _, _ in
        Issue.record("queryHandler should not be called for an unsupported operator")
        throw TestFileMakerProbeError.stopAfterCapture
    }
    let request = try LassoInlineRequest(arguments: [
        EvaluatedArgument(label: "database", value: .string("fm_catalog")),
        EvaluatedArgument(label: "table", value: .string("storefront")),
        EvaluatedArgument(label: "search", value: .boolean(true)),
        EvaluatedArgument(label: "op", value: .string("rx")),
        EvaluatedArgument(label: "status", value: .string("unchecked")),
    ])
    // Structural/programmer-facing -- not caught by this executor's
    // LassoFileMakerDatabaseActionError handling, so it propagates as a
    // genuine Swift throw rather than becoming a silently-recoverable frame.
    await #expect(throws: LassoFileMakerLassoError.unsupportedComparison("rx")) {
        try await executor.execute(request)
    }
}

@Test func fileMakerExecutorMapsFindAllActionWithSortAndPaging() async throws {
    final class Capture: @unchecked Sendable {
        var query: FMPQuery?
    }
    let capture = Capture()
    let executor = PerfectFileMakerLassoExecutor { query, _, _ in
        capture.query = query
        throw TestFileMakerProbeError.stopAfterCapture
    }
    let request = try LassoInlineRequest(arguments: [
        EvaluatedArgument(label: "database", value: .string("fm_catalog")),
        EvaluatedArgument(label: "table", value: .string("storefront")),
        EvaluatedArgument(label: "findall", value: .boolean(true)),
        EvaluatedArgument(label: "sortfield", value: .string("last_name")),
        EvaluatedArgument(label: "sortorder", value: .string("descending")),
        EvaluatedArgument(label: "maxrecords", value: .integer(25)),
        EvaluatedArgument(label: "skiprecords", value: .integer(50)),
    ])
    _ = try? await executor.execute(request)
    let queryString = try #require(capture.query?.queryString)
    #expect(queryString.contains("-findall"))
    #expect(queryString.contains("-sortfield.1=last_name"))
    #expect(queryString.contains("-sortorder.1=descend"))
    #expect(queryString.contains("-skip=50"))
    #expect(queryString.contains("-max=25"))
}

@Test func fileMakerExecutorMapsAddActionWithFieldAssignments() async throws {
    final class Capture: @unchecked Sendable {
        var query: FMPQuery?
    }
    let capture = Capture()
    let executor = PerfectFileMakerLassoExecutor(allowWrites: true) { query, _, _ in
        capture.query = query
        throw TestFileMakerProbeError.stopAfterCapture
    }
    let request = try LassoInlineRequest(arguments: [
        EvaluatedArgument(label: "database", value: .string("fm_catalog")),
        EvaluatedArgument(label: "table", value: .string("storefront")),
        EvaluatedArgument(label: "add", value: .boolean(true)),
        EvaluatedArgument(label: "status", value: .string("new")),
    ])
    _ = try? await executor.execute(request)
    let queryString = try #require(capture.query?.queryString)
    #expect(queryString.contains("-new"))
    #expect(queryString.contains("status"))
}

@Test func fileMakerExecutorMapsUpdateActionWithRecordIdFromKeyValue() async throws {
    final class Capture: @unchecked Sendable {
        var query: FMPQuery?
    }
    let capture = Capture()
    let executor = PerfectFileMakerLassoExecutor(allowWrites: true) { query, _, _ in
        capture.query = query
        throw TestFileMakerProbeError.stopAfterCapture
    }
    let request = try LassoInlineRequest(arguments: [
        EvaluatedArgument(label: "database", value: .string("fm_catalog")),
        EvaluatedArgument(label: "table", value: .string("storefront")),
        EvaluatedArgument(label: "update", value: .boolean(true)),
        // Real corpus always passes -KeyField as empty -- FileMaker's key
        // field is always the internal record id, only -KeyValue matters.
        EvaluatedArgument(label: "keyfield", value: .string("")),
        EvaluatedArgument(label: "keyvalue", value: .integer(101)),
        EvaluatedArgument(label: "status", value: .string("checked")),
    ])
    _ = try? await executor.execute(request)
    let queryString = try #require(capture.query?.queryString)
    #expect(queryString.contains("-recid=101"))
    #expect(queryString.contains("-edit"))
}

@Test func fileMakerExecutorMapsDeleteActionWithRecordId() async throws {
    final class Capture: @unchecked Sendable {
        var query: FMPQuery?
    }
    let capture = Capture()
    let executor = PerfectFileMakerLassoExecutor(allowWrites: true) { query, _, _ in
        capture.query = query
        throw TestFileMakerProbeError.stopAfterCapture
    }
    let request = try LassoInlineRequest(arguments: [
        EvaluatedArgument(label: "database", value: .string("fm_catalog")),
        EvaluatedArgument(label: "table", value: .string("storefront")),
        EvaluatedArgument(label: "delete", value: .boolean(true)),
        EvaluatedArgument(label: "keyfield", value: .string("")),
        EvaluatedArgument(label: "keyvalue", value: .integer(101)),
    ])
    _ = try? await executor.execute(request)
    let queryString = try #require(capture.query?.queryString)
    #expect(queryString.contains("-recid=101"))
    #expect(queryString.contains("-delete"))
}

@Test func fileMakerExecutorTurnsClassifiedHandlerFailureIntoRecoverableFrame() async throws {
    // Mirrors what the real production `queryHandler` (built in
    // main.swift, wrapping a semaphore-bridged FileMakerServer call) is
    // expected to do: catch its own real backend failure and throw
    // LassoFileMakerDatabaseActionError itself, since it -- not this
    // executor -- is the only place with enough context (kind/datasource
    // are passed to it directly) to classify the failure.
    struct FakeServerError: Error {}
    let executor = PerfectFileMakerLassoExecutor { _, kind, datasource in
        throw LassoFileMakerDatabaseActionError(kind: kind, datasource: datasource, underlying: FakeServerError())
    }
    let request = try LassoInlineRequest(arguments: [
        EvaluatedArgument(label: "database", value: .string("fm_catalog")),
        EvaluatedArgument(label: "table", value: .string("storefront")),
        EvaluatedArgument(label: "findall", value: .boolean(true)),
    ])
    let frame = try await executor.execute(request)
    #expect(frame.rows == [])
    #expect(frame.error != .noError)
    #expect(frame.error.kind == "search")
    #expect(frame.error.detail?.contains("FakeServerError") == true)
}

@Test func fileMakerExecutorPropagatesUnclassifiedHandlerFailureFatally() async throws {
    // The inverse of the above: an UNclassified error from the handler
    // (a bug in the semaphore bridge, or any failure it forgot to wrap)
    // must NOT be silently downgraded into a routine recoverable frame --
    // matching PerfectCRUDLassoExecutor, whose own do/catch around
    // queryHandler only catches LassoRecoverableError/LassoDatabaseActionError
    // and lets anything else propagate. Swift Testing's #expect(throws:)
    // can't match a non-Equatable error by value, so this asserts the
    // throw happens and (separately) that it's the same instance.
    struct FakeBugError: Error {}
    let executor = PerfectFileMakerLassoExecutor { _, _, _ in
        throw FakeBugError()
    }
    let request = try LassoInlineRequest(arguments: [
        EvaluatedArgument(label: "database", value: .string("fm_catalog")),
        EvaluatedArgument(label: "table", value: .string("storefront")),
        EvaluatedArgument(label: "findall", value: .boolean(true)),
    ])
    await #expect {
        try await executor.execute(request)
    } throws: { error in
        error is FakeBugError
    }
}

@Test func fileMakerExecutorRendersRecoverableErrorThroughInlineWhenWritesDisabled() async throws {
    let executor = PerfectFileMakerLassoExecutor(allowWrites: false) { _, _, _ in
        throw TestFileMakerProbeError.stopAfterCapture
    }
    let provider = LassoDynamicInlineProvider(executor: executor, datasourceAliases: ["fm_catalog": "fm_catalog"])
    var context = LassoContext(inlineProvider: provider)
    let output = try await LassoRenderer().render(
        "[inline(-database='fm_catalog',-table='storefront',-add,'status'='new')][/inline][error_currenterror]",
        context: &context
    )
    #expect(output.contains("not enabled"))
}

@Test func lassoValueMapsFileMakerFieldTypesToLassoValue() throws {
    let executor = PerfectFileMakerLassoExecutor(baseURL: "http://203.0.113.10:80") { _, _, _ in
        throw TestFileMakerProbeError.stopAfterCapture
    }
    #expect(executor.lassoValue(.text("Jane Doe")) == .string("Jane Doe"))
    #expect(executor.lassoValue(.number(42.5)) == .decimal(42.5))
    #expect(executor.lassoValue(.date("07/12/2026")) == .string("07/12/2026"))
    #expect(executor.lassoValue(.time("14:30:00")) == .string("14:30:00"))
    #expect(executor.lassoValue(.timestamp("07/12/2026 14:30:00")) == .string("07/12/2026 14:30:00"))
    // Server-relative container path -- prefixed with the configured base URL.
    #expect(executor.lassoValue(.container("/fmi/xml/cnt/photo.jpg?-db=fm_catalog")) ==
        .string("http://203.0.113.10:80/fmi/xml/cnt/photo.jpg?-db=fm_catalog"))
    // Already-absolute container reference -- passed through unprefixed.
    #expect(executor.lassoValue(.container("http://elsewhere/photo.jpg")) == .string("http://elsewhere/photo.jpg"))
}

@Test func perfectCRUDExecutorRoutesAddUpdateDeleteToTheMutationHandler() async throws {
    final class MutationRecorder: @unchecked Sendable {
        private(set) var mutations: [DynamicMutation] = []
        func record(_ mutation: DynamicMutation) { mutations.append(mutation) }
    }
    let recorder = MutationRecorder()
    let executor = PerfectCRUDLassoExecutor(
        capabilities: { _ in .full },
        queryHandler: { _, _ in DynamicResult(rows: [], statement: "SELECT ...") },
        mutationHandler: { datasource, mutation in
            #expect(datasource == "catalog")
            recorder.record(mutation)
            return DynamicResult(rows: [], affectedRows: 1, statement: "...", insertedID: mutation.action == .insert ? 99 : nil)
        }
    )
    let provider = LassoDynamicInlineProvider(executor: executor, datasourceAliases: ["catalog_mysql": "catalog"])
    var context = LassoContext(inlineProvider: provider)

    _ = try await LassoRenderer().render(
        "[inline(-database='catalog_mysql',-table='skus',-add,'color'='red')][/inline]",
        context: &context
    )
    _ = try await LassoRenderer().render(
        "[inline(-database='catalog_mysql',-table='skus',-update,-keyfield='id',-keyvalue=7,'color'='blue')][/inline]",
        context: &context
    )
    _ = try await LassoRenderer().render(
        "[inline(-database='catalog_mysql',-table='skus',-delete,-keyfield='id',-keyvalue=7)][/inline]",
        context: &context
    )

    let seenMutations = recorder.mutations
    #expect(seenMutations.count == 3)
    #expect(seenMutations[0].action == .insert)
    #expect(seenMutations[0].table == "skus")
    #expect(seenMutations[0].values == ["color": .string("red")])
    #expect(seenMutations[0].predicates == [])

    #expect(seenMutations[1].action == .update)
    #expect(seenMutations[1].values == ["color": .string("blue")])
    #expect(seenMutations[1].predicates == [DynamicPredicate(field: "id", comparison: .equal, value: .int(7))])

    #expect(seenMutations[2].action == .delete)
    #expect(seenMutations[2].values == [:])
    #expect(seenMutations[2].predicates == [DynamicPredicate(field: "id", comparison: .equal, value: .int(7))])
}

@Test func perfectCRUDExecutorRoutesRawSQLToTheRawSQLHandler() async throws {
    final class SQLRecorder: @unchecked Sendable {
        private(set) var sql: DynamicSQL?
        func record(_ sql: DynamicSQL) { self.sql = sql }
    }
    let recorder = SQLRecorder()
    let executor = PerfectCRUDLassoExecutor(
        capabilities: { _ in .full },
        queryHandler: { _, _ in DynamicResult(rows: [], statement: "") },
        rawSQLHandler: { datasource, sql in
            #expect(datasource == "catalog")
            recorder.record(sql)
            return DynamicResult(rows: [DynamicRow(["n": .int(3)])], affectedRows: 0, statement: sql.sql)
        }
    )
    var context = LassoContext(inlineProvider: LassoDynamicInlineProvider(
        executor: executor,
        datasourceAliases: ["catalog_mysql": "catalog"]
    ))
    let output = try await LassoRenderer().render(
        "[inline(-database='catalog_mysql',-sql='SELECT COUNT(*) AS n FROM skus')][records][field('n')][/records][/inline]",
        context: &context
    )
    #expect(output == "3")
    #expect(recorder.sql?.sql == "SELECT COUNT(*) AS n FROM skus")
}

@Test func writeAndRawSQLCapabilitiesDenyByDefaultAsRecoverableErrors() async throws {
    // Documentation/inline-write-raw-sql-plan.md's Capability Policy:
    // reads enabled by default, writes/raw SQL disabled until a datasource
    // explicitly opts in. Denial surfaces as an inline frame carrying
    // LassoErrorState -- the SAME mechanism a real database permission
    // error would use (pushInlineFrame sets context.currentError from the
    // frame automatically) -- not a thrown error, so this doesn't even
    // need a protect wrapper to observe: error_currentError just reflects
    // it once the inline block runs.
    let executor = PerfectCRUDLassoExecutor(
        queryHandler: { _, _ in DynamicResult(rows: [], statement: "") },
        mutationHandler: { _, mutation in DynamicResult(rows: [], affectedRows: 1, statement: "") },
        rawSQLHandler: { _, sql in DynamicResult(rows: [], statement: sql.sql) }
    )
    var context = LassoContext(inlineProvider: LassoDynamicInlineProvider(
        executor: executor,
        datasourceAliases: ["catalog_mysql": "catalog"]
    ))
    let output = try await LassoRenderer().render(
        """
        [inline(-database='catalog_mysql',-table='skus',-add,'color'='red')][/inline]\
        error=[error_currenterror]
        """,
        context: &context
    )
    #expect(output == "error=-Add is not enabled for datasource 'catalog'.")
}

@Test(
    "PerfectCRUD connector failures become inline error frames",
    arguments: [
        (
            "[inline(-database='catalog_mysql',-table='skus',-search)][error_currenterror]|[error_currenterror(-errorcode)][/inline]",
            "Search failed for datasource 'catalog'.|1007"
        ),
        (
            "[inline(-database='catalog_mysql',-table='skus',-add,'color'='red')][error_currenterror]|[error_currenterror(-errorcode)][/inline]",
            "Add failed for datasource 'catalog'.|1001"
        ),
        (
            "[inline(-database='catalog_mysql',-table='skus',-update,-keyfield='id',-keyvalue=7,'color'='blue')][error_currenterror]|[error_currenterror(-errorcode)][/inline]",
            "Update failed for datasource 'catalog'.|1002"
        ),
        (
            "[inline(-database='catalog_mysql',-table='skus',-delete,-keyfield='id',-keyvalue=7)][error_currenterror]|[error_currenterror(-errorcode)][/inline]",
            "Delete failed for datasource 'catalog'.|1003"
        ),
        (
            "[inline(-database='catalog_mysql',-sql='SELECT * FROM skus')][error_currenterror]|[error_currenterror(-errorcode)][/inline]",
            "SQL failed for datasource 'catalog'.|1008"
        ),
    ]
)
func perfectCRUDConnectorFailuresBecomeInlineErrorFrames(source: String, expected: String) async throws {
    enum ConnectorFailure: Error {
        case unavailable
    }

    let executor = PerfectCRUDLassoExecutor(
        capabilities: { _ in .full },
        queryHandler: { datasource, _ in
            throw LassoDatabaseActionError(kind: .search, datasource: datasource, underlying: ConnectorFailure.unavailable)
        },
        mutationHandler: { datasource, mutation in
            let kind: LassoDatabaseActionFailureKind = switch mutation.action {
            case .insert: .add
            case .update: .update
            case .delete: .delete
            }
            throw LassoDatabaseActionError(kind: kind, datasource: datasource, underlying: ConnectorFailure.unavailable)
        },
        rawSQLHandler: { datasource, _ in
            throw LassoDatabaseActionError(kind: .sql, datasource: datasource, underlying: ConnectorFailure.unavailable)
        }
    )
    var context = LassoContext(inlineProvider: LassoDynamicInlineProvider(
        executor: executor,
        datasourceAliases: ["catalog_mysql": "catalog"]
    ))

    let output = try await LassoRenderer().render(source, context: &context)
    #expect(output == expected)
}

@Test func perfectCRUDExecutorPreservesRecoverableErrorsThrownByHandlers() async throws {
    let state = LassoErrorState(code: 4242, message: "Connector-specific failure", kind: "connector")
    let executor = PerfectCRUDLassoExecutor(
        capabilities: { _ in .full },
        queryHandler: { _, _ in throw LassoRecoverableError(state) }
    )
    var context = LassoContext(inlineProvider: LassoDynamicInlineProvider(
        executor: executor,
        datasourceAliases: ["catalog_mysql": "catalog"]
    ))

    let output = try await LassoRenderer().render(
        "[inline(-database='catalog_mysql',-table='skus',-search)][error_currenterror]|[error_currenterror(-errorcode)][/inline]",
        context: &context
    )

    #expect(output == "Connector-specific failure|4242")
}

@Test func perfectCRUDExecutorStillThrowsFatalValidationErrorsBeforeConnectorCalls() async throws {
    let executor = PerfectCRUDLassoExecutor(
        queryHandler: { _, _ in DynamicResult(rows: [], statement: "") }
    )
    var context = LassoContext(inlineProvider: LassoDynamicInlineProvider(
        executor: executor,
        datasourceAliases: ["catalog_mysql": "catalog"]
    ))

    await #expect(throws: PerfectCRUDLassoError.missingTable) {
        _ = try await LassoRenderer().render(
            "[inline(-database='catalog_mysql',-search)][error_currenterror][/inline]",
            context: &context
        )
    }
}

@Test func perfectCRUDExecutorDoesNotFrameUnknownHandlerThrows() async throws {
    enum ProgrammerError: Error, Equatable {
        case unexpected
    }

    let executor = PerfectCRUDLassoExecutor(
        queryHandler: { _, _ in throw ProgrammerError.unexpected }
    )
    var context = LassoContext(inlineProvider: LassoDynamicInlineProvider(
        executor: executor,
        datasourceAliases: ["catalog_mysql": "catalog"]
    ))

    await #expect(throws: ProgrammerError.unexpected) {
        _ = try await LassoRenderer().render(
            "[inline(-database='catalog_mysql',-table='skus',-search)][error_currenterror][/inline]",
            context: &context
        )
    }
}

@Test func customTagDefinesCallsAndIsolatesLocals() async throws {
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
    let output = try await LassoRenderer().render(source, context: &context)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    #expect(output == "Hello, Ada! / Hi, Bo! / 6 / 100 / early / late")
}

@Test func tagExistsChecksNativeFunctionsAndCustomTags() async throws {
    var nativeContext = LassoContext()
    let nativeOutput = try await LassoRenderer().render(
        "[lasso_tagexists('string')]|[tag_exists('lasso_tagexists')]|[tag_exists('missing_tag')]",
        context: &nativeContext
    )
    #expect(nativeOutput == "true|true|false")

    var customContext = LassoContext()
    let customOutput = try await LassoRenderer().render(
        "<?lassoscript define sample_tag() => { return 'ok' } ?>[lasso_tagexists('sample_tag')]|[tag_exists('sample_tag')]",
        context: &customContext
    )
    #expect(customOutput == "true|true")
}

@Test func typeDefinitionsConstructObjectsAndDispatchMethods() async throws {
    var context = LassoContext()
    let output = try await LassoRenderer().render(
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

@Test func legacyDefineTagParenthesizedRegistersStandaloneTag() async throws {
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        """
        [
        Define_Tag('Greet', -Required='Name', -Optional='Greeting');
            Return((Local_Defined: 'Greeting') ? (Local: 'Greeting') + ', ' + (Local: 'Name') | 'Hello, ' + (Local: 'Name'));
        /Define_Tag;
        ]
        [Greet: 'Ada']|[Greet: 'Ada', 'Hi']
        """,
        context: &context
    ).trimmingCharacters(in: .whitespacesAndNewlines)

    #expect(output == "Hello, Ada|Hi, Ada")
}

@Test func legacyDefineTagColonCallRegistersStandaloneTagWithTypeConstrainedParameters() async throws {
    // Real corpus shape (see Documentation/legacy-define-tag-type-plan.md,
    // "Parenthesized Legacy Custom Tag" and colon-call variants): no
    // enclosing parens after the colon, -Required/-Type pairs declaring
    // typed parameters.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        """
        [
        Define_Tag: 'Ex_Sum', -Required='A', -Type='integer', -Required='B', -Type='integer';
            Return((Local: 'A') + (Local: 'B'));
        /Define_Tag;
        ]
        [Ex_Sum: 3, 4]
        """,
        context: &context
    ).trimmingCharacters(in: .whitespacesAndNewlines)

    #expect(output == "7")
}

@Test func legacyDefineTypeParenthesizedRegistersDataMembersAndMethodsWithConstructorParams() async throws {
    // Scrubbed version of the real getGeoIPInfo.inc shape: a data member
    // default that reads the constructor's own `params` (Documentation/
    // legacy-define-tag-type-plan.md's "Constructor params" note), plus a
    // nested define_tag method reading/writing instance data via self.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        """
        [
        Define_Type('Ex_Info');
            Local(
                'label' = (Params->First ? Params->First | 'default'),
                'country' = 'unknown'
            );
            Define_Tag('describe');
                Self->'country' = 'US';
                Return((Self->'label') + '/' + (Self->'country'));
            /Define_Tag;
        /Define_Type;
        ]
        [Local(withArg = Ex_Info('custom'))][Local(withoutArg = Ex_Info())][#withArg->describe]|[#withoutArg->describe]
        """,
        context: &context
    ).trimmingCharacters(in: .whitespacesAndNewlines)

    #expect(output == "custom/US|default/US")
}

@Test func legacyDefineTypeColonCallRegistersTypeAndMethods() async throws {
    // Scrubbed version of the real js_timer.inc shape: colon-call
    // define_type with a parent/base type name and -prototype flag
    // (parsed, not yet acted on — see the plan's deferred inheritance
    // note), a colon-call local: data member, and colon-call define_tag:
    // methods using parenthesized self->'member' assignment.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        """
        [
        define_type: 'Ex_Timer', 'integer', -prototype;
            local: 'ticks'=0;

            define_tag: 'bump';
                (self->'ticks') = (self->'ticks') + 1;
            /define_tag;

            define_tag: 'value';
                return: (self->'ticks');
            /define_tag;
        /define_type;
        ]
        [Local(t = Ex_Timer())][#t->bump][#t->bump][#t->value]
        """,
        context: &context
    ).trimmingCharacters(in: .whitespacesAndNewlines)

    #expect(output == "2")
}

@Test func customTagRecursionSucceedsAndDeepRecursionThrows() async throws {
    var context = LassoContext()
    let output = try await LassoRenderer().render(
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
    await #expect(throws: LassoRuntimeError.tagCallDepthExceeded) {
        try await LassoRenderer().render(
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

@Test func libraryDedupesWithinOneRenderButReloadsPerIndependentContext() async throws {
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
    let firstOutput = try await LassoRenderer().render(
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
    let secondOutput = try await LassoRenderer().render(
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

@Test func includeAlwaysRereadsButSkipsReparseWhenUnchanged() async throws {
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

    func render(_ source: String) async throws -> String {
        var context = LassoContext(includeLoader: loader, tagRegistry: registry)
        return try await LassoRenderer().render(source, context: &context)
    }

    #expect(try await render("[include('shared.lasso')]") == "v1: 1")
    #expect(try await render("[include('shared.lasso')]") == "v1: 1")
    #expect(loader.loadCount == 2, "An include is re-read (I/O) on every use, unlike a library")

    loader.content = "v2: [local(x = 2)][#x]"
    #expect(
        try await render("[include('shared.lasso')]") == "v2: 2",
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

@Test func lassoDelimiterSupportsBraceStyleBlocks() async throws {
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
    let output = try await LassoRenderer().render(source, context: &context)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    #expect(
        output == "true/yes/done",
        "Content after the closing '}' must not be swallowed into the if's body"
    )
}

@Test func lassoDelimiterBraceStyleIfElseChoosesCorrectBranch() async throws {
    var context = LassoContext()

    let trueOutput = try await LassoRenderer().render(
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

    let falseOutput = try await LassoRenderer().render(
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

@Test func bareConditionBraceIfWithNoParensAndNoArrowIsRecognizedAsRealControlFlow() async throws {
    // A THIRD `if` syntax variant found live in
    // components/site_setup_tags.inc's excludeBots(): a bare (paren-less)
    // condition immediately followed by a brace body, no `=>` arrow at
    // all (`if #request == '' { ... } else { ... }`) — distinct from both
    // `if(cond) ... /if` and `if(cond) => { ... }`. Before this fix,
    // parseBlockOpening required an immediate '(' after "if", so this fell
    // through entirely to being parsed as a bare ExpressionParser
    // expression with no concept of brace bodies — the lexer tokenized
    // the bare '{' as a symbol, producing .unknown("{"), which threw at
    // evaluation. This was a real, live-blocking bug: excludeBots is
    // called unconditionally on every page via _begin.lasso -> library().
    var context = LassoContext()

    let emptyOutput = try await LassoRenderer().render(
        """
        <?lasso
        define classify(request::String) => {
            if #request == '' {
                return 'empty'
            } else {
                return 'has-value'
            }
        }
        ?>
        [classify('')]
        """,
        context: &context
    ).trimmingCharacters(in: .whitespacesAndNewlines)
    #expect(emptyOutput == "empty")

    let nonEmptyOutput = try await LassoRenderer().render(
        """
        <?lasso
        define classify(request::String) => {
            if #request == '' {
                return 'empty'
            } else {
                return 'has-value'
            }
        }
        ?>
        [classify('Mozilla/5.0')]
        """,
        context: &context
    ).trimmingCharacters(in: .whitespacesAndNewlines)
    #expect(nonEmptyOutput == "has-value")
}

@Test func colonCallIfOpenerIsRecognizedAsRealControlFlow() async throws {
    // Lasso 8's colon-call convention (`if:(condition);` ... `else;` ...
    // `/if;`) is just as valid an opener as the parenthesized-call style —
    // found live-verifying a real corpus page, where `if:(...)` fell
    // through to being parsed as an ordinary colon-call expression
    // statement (`if` treated as a bare function name), throwing
    // unknownFunction("if") instead of ever reaching real control flow.
    var context = LassoContext()

    let trueOutput = try await LassoRenderer().render(
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

    let falseOutput = try await LassoRenderer().render(
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

@Test func bareColonCallIfOpenerWithNoParensIsRecognizedAsRealControlFlow() async throws {
    // Lasso 8's classic slash-closed colon-call with a bare (paren-less)
    // condition — `if: cond; ... /if;` — distinct from both `if(cond)`
    // and `if:(cond)`. Real corpus: importscripts/ca_web.lasso and 17
    // other pages (`if: error_currenterror!='No error'; ... /if;`), all
    // of which fell through to unknownFunction("if") before this fix,
    // since classifyIfOpen only recognized a bare condition immediately
    // followed by a brace body, not one terminated by ';' with no braces
    // at all.
    var context = LassoContext()

    let trueOutput = try await LassoRenderer().render(
        """
        <?lasso
        if: true;
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

    let falseOutput = try await LassoRenderer().render(
        """
        <?lasso
        if: false;
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

@Test func bareColonCallIfOpenerWithNoElseAndNoTrailingSemicolonStillParses() async throws {
    // Real corpus shape (importscripts/ca_web.lasso:30): a bare condition
    // with a comparison operator, no else branch, condition itself ends
    // the statement with ';' before the block body begins on the next line.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        """
        <?lasso
        #x = 'No error';
        $branch = 'unset';
        if: #x!='No error';
            $branch = 'error'
        /if;
        ?>
        [$branch]
        """,
        context: &context
    ).trimmingCharacters(in: .whitespacesAndNewlines)
    #expect(output == "unset")
}

@Test func lassoDelimiterMixesBraceAndSlashStyleNesting() async throws {
    var context = LassoContext()
    let output = try await LassoRenderer().render(
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

@Test func lassoDelimiterRealCorpusShapeNoLongerThrowsUnknownFunctionIf() async throws {
    var context = LassoContext()
    let output = try await LassoRenderer().render(
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

@Test func arrowBraceBodyOnItsOwnLineIsNotMalformed() async throws {
    // Real startup-folder code commonly puts the opening brace on the line
    // after '=>' rather than immediately following it (found verifying
    // against a real LassoStartup folder — a `define name(...) =>` /
    // `{` split like this used to make parseDefineOpening back out
    // entirely, silently reinterpreting the define as a plain statement
    // and later throwing unknownFunction for the tag's own name).
    var context = LassoContext()
    let output = try await LassoRenderer().render(
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

@Test func arrowBraceIfBodyOnItsOwnLineIsRecognized() async throws {
    var context = LassoContext()
    let output = try await LassoRenderer().render(
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

@Test func slashStyleBlockBodyIsNotSwallowedWhenNoArrowFollows() async throws {
    // Regression guard for a bug introduced while fixing the arrow-brace
    // newline case above: consumeArrowBlockStartIfPresent() must not
    // cross a newline while merely probing for '=>' — doing so left the
    // parser positioned on the block body's first line, which the
    // caller's unconditional skipLineRemainder() then silently swallowed
    // instead of just cleaning up the block-opening line's own trailer.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
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

@Test func crlfLineEndingsDoNotSwallowArrowBraceBlockBodies() async throws {
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
    let output = try await LassoRenderer().render(source, context: &context)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    #expect(output == "1")
}

@Test func expressionBodiedDefineRegistersStringLiteralConstant() async throws {
    // Real startup-folder shape: `define br => '<br />'` — no braces at
    // all, just a bare expression. Before this fix, parseDefineOpening
    // backed out entirely on seeing no '{', so `br` was never registered
    // and got parsed as an ordinary (undefined) function call instead.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
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

@Test func expressionBodiedDefineSupportsMultiLineArrayAndMapLiterals() async throws {
    // Real shape: `define botMap => array(...)` / `define keywordMap =>
    // map(...)` spanning multiple lines. readStatement()'s paren-depth
    // tracking must treat the whole multi-line call as one statement, not
    // stop at each internal newline.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
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

@Test func bareIdentifierCallsZeroArgCustomTag() async throws {
    var context = LassoContext()
    let output = try await LassoRenderer().render(
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

@Test func typeDataMemberDefaultValueResolvesBareZeroArgTagCall() async throws {
    // Mirrors the real pp_express type exactly: `data public returnURL =
    // pp_return`, where `pp_return` is itself an expression-bodied
    // zero-arg define, referenced with no parens.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
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

@Test func withInDoIteratesArrayBindingNamedVariable() async throws {
    var context = LassoContext()
    let output = try await LassoRenderer().render(
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

@Test func withInDoIteratesOverBareZeroArgTagCallResult() async throws {
    // End-to-end composition of all three fixes in this pass, mirroring
    // the real excludeBots/botMap shape exactly: a with...do body iterates
    // a bare-referenced expression-bodied array constant.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
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

@Test func excludeBotsFullRealShapeRedirectsUsingWebRequestHttpHost() async throws {
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
    let output = try await LassoRenderer().render(
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

@Test func malformedWithFallsBackToOrdinaryCodeWithoutSwallowingNextStatement() async throws {
    // Regression guard, same class as slashStyleBlockBodyIsNotSwallowedWhenNoArrowFollows:
    // a bare 'with' not actually followed by 'name in expr do {' must not
    // crash or eat the statement after it.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
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

@Test func nativeReceiverIsAssignableFirstClassValue() async throws {
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
    let output = try await LassoRenderer().render(
        "<?lasso local(r = web_request) ?>[#r->param('term')]",
        context: &context
    ).trimmingCharacters(in: .whitespacesAndNewlines)
    #expect(output == "clogs")
}

@Test func webRequestMembersReflectRealRequestData() async throws {
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
    let output = try await LassoRenderer().render(
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
    let bulkOutput = try await LassoRenderer().render(
        "[web_request->headers->host]/[web_request->cookies->sid]/[web_request->params->term]",
        context: &context
    )
    #expect(bulkOutput == "shop.example.test/abc123/clogs")
}

@Test func webRequestPostParamsAreEmptyNotBroken() async throws {
    // Documented limitation, not a silent failure: this interpreter has
    // never parsed POST bodies (tracked separately). postParam/postParams/
    // postString return empty results — the same shape a real request
    // with no matching data would produce — rather than throwing.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        "[web_request->postParam('x')]|[web_request->postString]",
        context: &context
    )
    #expect(output == "|")
}

@Test func postBodySupportsRealFormDataWithPostBeforeGetOrdering() async throws {
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
    let output = try await LassoRenderer().render(
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

@Test func actionParamsReturnsOrderedPairsPostBeforeGet() async throws {
    // Real corpus shape (includes/send_debug_email.include.lasso):
    // Loop(action_params->size); ... action_params->get(n)->first/second ...
    // -- action_params (plural) must be an ordered array of name/value
    // pairs, duplicates and all, unlike action_param's dictionary-shaped
    // single-value lookup. Previously unregistered entirely, so the bare
    // identifier resolved to .null and ->size threw
    // unsupportedExpression("Member size").
    struct FormRequestProvider: LassoRequestProvider {
        let queryPairs: [LassoRequestPair] = [
            LassoRequestPair(name: "term", value: .string("from-query")),
        ]
        let postPairs: [LassoRequestPair] = [
            LassoRequestPair(name: "color", value: .string("red")),
            LassoRequestPair(name: "color", value: .string("blue")),
        ]
        func parameter(named name: String) -> LassoValue {
            (postPairs + queryPairs).first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value ?? .void
        }
        func header(named name: String) -> LassoValue { .void }
        func cookie(named name: String) -> LassoValue { .void }
        var parameters: [String: LassoValue] {
            Dictionary((postPairs + queryPairs).map { ($0.name.lowercased(), $0.value) }, uniquingKeysWith: { first, _ in first })
        }
    }

    var context = LassoContext(requestProvider: FormRequestProvider())
    let output = try await LassoRenderer().render(
        """
        [action_params->size]|\
        [action_params->get(1)->first]=[action_params->get(1)->second]|\
        [action_params->get(2)->first]=[action_params->get(2)->second]|\
        [action_params->get(3)->first]=[action_params->get(3)->second]
        """,
        context: &context
    )
    #expect(output == "3|color=red|color=blue|term=from-query")
}

@Test func fileUploadsExposeMetadataUnderBothLasso9And8KeyNames() async throws {
    // Documentation/session-upload-support-plan.md Milestone 1:
    // web_request->fileUploads() (Lasso 9 keys) and [file_uploads] (Lasso 8
    // keys) both project the same real upload metadata, just under each
    // dialect's own documented field names. The temp file's actual bytes
    // aren't this interpreter's concern — only the metadata Lasso code
    // needs to locate and read/move the file itself.
    struct UploadRequestProvider: LassoRequestProvider {
        let uploadedFiles: [LassoUploadedFile] = [
            LassoUploadedFile(
                fieldName: "avatar",
                contentType: "image/png",
                originalFilename: "photo.png",
                temporaryFilename: "/tmp/upload-abc123",
                size: 4096
            ),
        ]
        func parameter(named name: String) -> LassoValue { .void }
        func header(named name: String) -> LassoValue { .void }
        func cookie(named name: String) -> LassoValue { .void }
        var parameters: [String: LassoValue] { [:] }
    }

    var context = LassoContext(requestProvider: UploadRequestProvider())
    let output = try await LassoRenderer().render(
        """
        [web_request->fileUploads->size]|\
        [web_request->fileUploads->get(1)->fieldname]|\
        [web_request->fileUploads->get(1)->contenttype]|\
        [web_request->fileUploads->get(1)->filename]|\
        [web_request->fileUploads->get(1)->tmpfilename]|\
        [web_request->fileUploads->get(1)->filesize]|\
        [file_uploads->get(1)->param]|\
        [file_uploads->get(1)->origname]|\
        [file_uploads->get(1)->type]|\
        [file_uploads->get(1)->size]|\
        [file_uploads->get(1)->origextension]
        """,
        context: &context
    )
    #expect(output == "1|avatar|image/png|photo.png|/tmp/upload-abc123|4096|avatar|photo.png|image/png|4096|png")
}

@Test func fileProcessUploadsMovesUploadedFilesIntoTheDestination() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("lasso-upload-root-\(UUID().uuidString)", isDirectory: true)
    let temp = FileManager.default.temporaryDirectory.appendingPathComponent("lasso-upload-temp-\(UUID().uuidString)")
    defer {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: temp)
    }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try "image-bytes".write(to: temp, atomically: true, encoding: .utf8)

    struct UploadRequestProvider: LassoRequestProvider {
        let uploadedFiles: [LassoUploadedFile]
        func parameter(named name: String) -> LassoValue { .void }
        func header(named name: String) -> LassoValue { .void }
        func cookie(named name: String) -> LassoValue { .void }
        var parameters: [String: LassoValue] { [:] }
    }

    let upload = LassoUploadedFile(
        fieldName: "avatar",
        contentType: "image/png",
        originalFilename: "photo.png",
        temporaryFilename: temp.path,
        size: 11
    )
    var context = LassoContext(
        requestProvider: UploadRequestProvider(uploadedFiles: [upload]),
        uploadProcessor: try LassoFileSystemUploadProcessor(root: root)
    )

    let output = try await LassoRenderer().render(
        "before-[File_ProcessUploads(-Destination='uploads')]-after",
        context: &context
    )

    let moved = root.appendingPathComponent("uploads/photo.png")
    #expect(output == "before--after")
    #expect(FileManager.default.fileExists(atPath: moved.path))
    #expect(FileManager.default.fileExists(atPath: temp.path) == false)
    #expect(try String(contentsOf: moved, encoding: .utf8) == "image-bytes")
}

@Test func fileProcessUploadsHonorsSizeAndExtensionFilters() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("lasso-upload-root-\(UUID().uuidString)", isDirectory: true)
    let small = FileManager.default.temporaryDirectory.appendingPathComponent("lasso-upload-small-\(UUID().uuidString)")
    let large = FileManager.default.temporaryDirectory.appendingPathComponent("lasso-upload-large-\(UUID().uuidString)")
    let wrongExtension = FileManager.default.temporaryDirectory.appendingPathComponent("lasso-upload-text-\(UUID().uuidString)")
    defer {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: small)
        try? FileManager.default.removeItem(at: large)
        try? FileManager.default.removeItem(at: wrongExtension)
    }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try "small".write(to: small, atomically: true, encoding: .utf8)
    try "large".write(to: large, atomically: true, encoding: .utf8)
    try "text".write(to: wrongExtension, atomically: true, encoding: .utf8)

    struct UploadRequestProvider: LassoRequestProvider {
        let uploadedFiles: [LassoUploadedFile]
        func parameter(named name: String) -> LassoValue { .void }
        func header(named name: String) -> LassoValue { .void }
        func cookie(named name: String) -> LassoValue { .void }
        var parameters: [String: LassoValue] { [:] }
    }

    var context = LassoContext(
        requestProvider: UploadRequestProvider(uploadedFiles: [
            LassoUploadedFile(fieldName: "a", contentType: "image/png", originalFilename: "small.png", temporaryFilename: small.path, size: 5),
            LassoUploadedFile(fieldName: "b", contentType: "image/png", originalFilename: "large.png", temporaryFilename: large.path, size: 50),
            LassoUploadedFile(fieldName: "c", contentType: "text/plain", originalFilename: "note.txt", temporaryFilename: wrongExtension.path, size: 4),
        ]),
        uploadProcessor: try LassoFileSystemUploadProcessor(root: root)
    )

    _ = try await LassoRenderer().render(
        "[File_ProcessUploads(-Destination='uploads', -Size=10, -Extensions='png')]",
        context: &context
    )

    #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("uploads/small.png").path))
    #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("uploads/large.png").path) == false)
    #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("uploads/note.txt").path) == false)
    #expect(FileManager.default.fileExists(atPath: large.path))
    #expect(FileManager.default.fileExists(atPath: wrongExtension.path))
}

@Test func fileProcessUploadsUsesTempNamesWhenRequested() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("lasso-upload-root-\(UUID().uuidString)", isDirectory: true)
    let temp = FileManager.default.temporaryDirectory.appendingPathComponent("upload-token-\(UUID().uuidString).tmp")
    defer {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: temp)
    }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try "payload".write(to: temp, atomically: true, encoding: .utf8)

    struct UploadRequestProvider: LassoRequestProvider {
        let uploadedFiles: [LassoUploadedFile]
        func parameter(named name: String) -> LassoValue { .void }
        func header(named name: String) -> LassoValue { .void }
        func cookie(named name: String) -> LassoValue { .void }
        var parameters: [String: LassoValue] { [:] }
    }

    let upload = LassoUploadedFile(
        fieldName: "avatar",
        contentType: "image/png",
        originalFilename: "photo.png",
        temporaryFilename: temp.path,
        size: 7
    )
    var context = LassoContext(
        requestProvider: UploadRequestProvider(uploadedFiles: [upload]),
        uploadProcessor: try LassoFileSystemUploadProcessor(root: root)
    )

    _ = try await LassoRenderer().render(
        "[File_ProcessUploads(-Destination='uploads', -UseTempNames)]",
        context: &context
    )

    #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("uploads/\(temp.lastPathComponent)").path))
    #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("uploads/photo.png").path) == false)
}

@Test func fileProcessUploadsOverwritePolicyAndPathConfinementAreRecoverable() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("lasso-upload-root-\(UUID().uuidString)", isDirectory: true)
    let temp = FileManager.default.temporaryDirectory.appendingPathComponent("lasso-upload-temp-\(UUID().uuidString)")
    defer {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: temp)
    }
    try FileManager.default.createDirectory(at: root.appendingPathComponent("uploads"), withIntermediateDirectories: true)
    try "old".write(to: root.appendingPathComponent("uploads/photo.png"), atomically: true, encoding: .utf8)
    try "new".write(to: temp, atomically: true, encoding: .utf8)

    struct UploadRequestProvider: LassoRequestProvider {
        let uploadedFiles: [LassoUploadedFile]
        func parameter(named name: String) -> LassoValue { .void }
        func header(named name: String) -> LassoValue { .void }
        func cookie(named name: String) -> LassoValue { .void }
        var parameters: [String: LassoValue] { [:] }
    }

    let upload = LassoUploadedFile(
        fieldName: "avatar",
        contentType: "image/png",
        originalFilename: "photo.png",
        temporaryFilename: temp.path,
        size: 3
    )
    var context = LassoContext(
        requestProvider: UploadRequestProvider(uploadedFiles: [upload]),
        uploadProcessor: try LassoFileSystemUploadProcessor(root: root)
    )

    let overwriteDenied = try await LassoRenderer().render(
        "[protect][File_ProcessUploads(-Destination='uploads')][/protect][error_currenterror]",
        context: &context
    )
    #expect(overwriteDenied == "File_ProcessUploads failed.")
    #expect(try String(contentsOf: root.appendingPathComponent("uploads/photo.png"), encoding: .utf8) == "old")

    let outsideRoot = try await LassoRenderer().render(
        "[protect][File_ProcessUploads(-Destination='../escape', -FileOverwrite)][/protect][error_currenterror]",
        context: &context
    )
    #expect(outsideRoot == "File_ProcessUploads failed.")
}

@Test func voidLookupMissBehavesLikeEmptyStringButNullStaysStrict() async throws {
    // Real Lasso 9 returns `void` (not `null`) when web_request->param /
    // action_param / header / cookie lookups miss, and keeps `null` itself
    // strict — an unhandled member on a real null throws unless the type
    // defines `_unknowntag`. The real corpus's near-universal
    // `action_param('template')->size` pattern (used in a log_critical
    // line on almost every real page) crashed before this: action_param
    // returned `.null` on a miss, and `.null` had no member-dispatch case
    // at all.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        "[action_param('missing')->size]|[action_param('missing')->contains('x')]|[action_param('missing')->uppercase]",
        context: &context
    )
    #expect(output == "0|false|")

    // A genuine null (not a lookup-miss void) must still throw on an
    // unhandled member — this fix must not weaken null's real strictness.
    var nullContext = LassoContext()
    await #expect(throws: LassoRuntimeError.unsupportedExpression("Member bogusMember")) {
        _ = try await LassoRenderer().render("[null->bogusMember]", context: &nullContext)
    }

    // The literal `void` keyword must itself parse to a real .void value
    // (previously both `null` and `void` collapsed to the same .null
    // expression node — harmless before this fix, but now `void` needs
    // its own distinct, permissive dispatch).
    var voidContext = LassoContext()
    let voidOutput = try await LassoRenderer().render("[void->size]", context: &voidContext)
    #expect(voidOutput == "0")
}

@Test func webResponseMembersRecordThroughResponseSink() async throws {
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
    _ = try await LassoRenderer().render(
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

// Real Lasso's Cookie_Set/web_response->setCookie pass name/value as a
// SINGLE argument whose LABEL is the cookie name and VALUE is the cookie
// value ('Cookie Name'='Cookie Value' per reference.lassosoft.com) --
// confirmed live 2026-07-18 against koi.scrubs.test's exact real corpus
// shape (includes/siteconfig_cookies.inc):
// `Cookie_Set('verify_cookies_active'='active', -Domain='iscrubs.com',
// -Path='/')` was producing `Set-Cookie: active=iscrubs.com` -- the real
// name was discarded, the value became the pair's own value, and THAT got
// overwritten by the next argument's (-Domain) value, because the
// previous implementation only checked -Name=/-Value= labeled arguments
// (never used anywhere in real corpus) and otherwise blindly took
// `arguments.first`/`arguments.dropFirst().first` regardless of label.
final class FullyRecordingResponseSink: LassoResponseSink, @unchecked Sendable {
    private(set) var cookies: [(name: String, value: String, domain: String?, expires: String?, path: String?, secure: Bool, httpOnly: Bool)] = []
    func setStatus(_ status: Int) throws {}
    func getStatus() -> Int { 200 }
    func redirect(to url: String) throws {}
    func setHeader(name: String, value: String) throws {}
    func setCookie(name: String, value: String) throws {
        try setCookie(name: name, value: value, domain: nil, expires: nil, path: nil, secure: false, httpOnly: false)
    }
    func setCookie(
        name: String, value: String, domain: String?, expires: String?,
        path: String?, secure: Bool, httpOnly: Bool
    ) throws {
        cookies.append((name, value, domain, expires, path, secure, httpOnly))
    }
}

@Test func cookieSetParsesTheRealNameEqualsValueArgumentForm() async throws {
    let sink = FullyRecordingResponseSink()
    var context = LassoContext(responseSink: sink)
    _ = try await LassoRenderer().render(
        "[Cookie_Set('verify_cookies_active'='active', -Domain='iscrubs.com', -Path='/')]",
        context: &context
    )
    #expect(sink.cookies.count == 1)
    #expect(sink.cookies.first?.name == "verify_cookies_active")
    #expect(sink.cookies.first?.value == "active")
    #expect(sink.cookies.first?.domain == "iscrubs.com")
    #expect(sink.cookies.first?.path == "/")
    #expect(sink.cookies.first?.expires == nil)
}

@Test func cookieSetStillSupportsTheExplicitNameValueLabeledForm() async throws {
    let sink = FullyRecordingResponseSink()
    var context = LassoContext(responseSink: sink)
    _ = try await LassoRenderer().render(
        "[Cookie_Set(-Name='sid', -Value='xyz')]",
        context: &context
    )
    #expect(sink.cookies.first?.name == "sid")
    #expect(sink.cookies.first?.value == "xyz")
}

@Test func cookieSetExpiresMinusOneProducesAnAlreadyExpiredHttpDate() async throws {
    // Real corpus (log_out.page.lasso, not_me.page.lasso,
    // process.page.lasso(.backup)) always uses -Expires='-1' to delete a
    // cookie -- documented as "expire immediately". The raw string "-1"
    // written verbatim into a Set-Cookie Expires= attribute is not a valid
    // HTTP-date and browsers won't reliably treat it as already-expired,
    // so this must convert to a real past date.
    let sink = FullyRecordingResponseSink()
    var context = LassoContext(responseSink: sink)
    _ = try await LassoRenderer().render(
        "[Cookie_Set('_LassoSessionTracker_scrubs_login'='', -Domain='koi.scrubs.test', -Expires='-1', -Path='/')]",
        context: &context
    )
    #expect(sink.cookies.first?.expires == "Thu, 01 Jan 1970 00:00:00 GMT")
}

@Test func cookieSetWithNoExpiresProducesASessionCookie() async throws {
    let sink = FullyRecordingResponseSink()
    var context = LassoContext(responseSink: sink)
    _ = try await LassoRenderer().render(
        "[Cookie_Set('a'='b')]",
        context: &context
    )
    #expect(sink.cookies.first?.expires == nil)
}

@Test func webResponseAbortStopsRenderingLikeReturn() async throws {
    // abort() rides the existing return-signal short-circuit mechanism —
    // no new control-flow needed. Verified the same way return's
    // short-circuit already is: output truncates at the abort point.
    // Needs real visible output before the abort() call to prove
    // truncation — a bare variable assignment doesn't itself produce any
    // output, so a test built only around one (as an earlier draft of
    // this test was) can't distinguish "stopped early" from "never
    // executed anything in the first place."
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        "BEFORE<?lasso web_response->abort() ?>AFTER",
        context: &context
    )
    #expect(output == "BEFORE")
}

@Test func sessionRemoveVarStopsPersistingAndEndDestroysTheSession() async throws {
    final class SessionProvider: LassoSessionProvider, @unchecked Sendable {
        private(set) var persisted: [String: [String: LassoValue]] = [:]
        private(set) var endedNames: Set<String> = []
        private var startedNames: Set<String> = []
        func start(session name: String, call: LassoSessionStartCall) async -> LassoSessionStartResult? {
            let isNew = startedNames.contains(name) == false
            startedNames.insert(name)
            return LassoSessionStartResult(sessionID: "fake-\(name)", isNew: isNew)
        }
        func id(session name: String) -> String? { startedNames.contains(name) ? "fake-\(name)" : nil }
        func restoredValue(for varName: String, session name: String) -> LassoValue? { nil }
        func persist(_ value: LassoValue, for varName: String, session name: String) {
            persisted[name, default: [:]][varName] = value
        }
        func removeVar(_ varName: String, session name: String) {
            persisted[name]?[varName] = nil
        }
        func end(session name: String) { endedNames.insert(name) }
        func abort(session name: String) {}
    }

    // removeVar: registered then removed before render ends — never persisted.
    let removeProvider = SessionProvider()
    var removeContext = LassoContext(sessionProvider: removeProvider)
    _ = try await LassoRenderer().render(
        "[session_start('cart')][var(a = 'x')][session_addvar('cart','a')][session_removevar('cart','a')]",
        context: &removeContext
    )
    #expect(removeProvider.persisted["cart"] == nil)

    // end: the provider is told the session ended; the real destroy/cookie
    // clearing happens at the server boundary (PerfectBackedLassoSessionProvider),
    // not here — this only proves the native reaches the provider.
    let endProvider = SessionProvider()
    var endContext = LassoContext(sessionProvider: endProvider)
    _ = try await LassoRenderer().render("[session_start('cart')][session_end('cart')]", context: &endContext)
    #expect(endProvider.endedNames.contains("cart"))
}

// The parse-time `LassoSessionPreflight` scan (and its tests, formerly
// here) was retired 2026-07-18 — `session_start` now creates/resumes its
// session directly, in place, exactly when evaluated (see
// `LassoSessionProvider`'s doc comment for the full architectural
// history). This makes the scan's own documented limitations moot rather
// than needing new test coverage: a dynamic session name, a dynamic flag
// value, and a `session_start` hidden inside any depth of `include(...)`
// nesting all now resolve correctly, because there's no separate
// parse-time step trying to see them ahead of render. See
// `sessionStartResolvesADynamicSessionNameAndFlagsAtEvaluationTime` and
// `perfectBackedSessionProviderPersistsVariablesAcrossTwoRequestsViaMemoryDriver`
// below for direct coverage of the new behavior.
@Test func sessionStartResolvesADynamicSessionNameAndFlagsAtEvaluationTime() async throws {
    final class SessionProvider: LassoSessionProvider, @unchecked Sendable {
        private(set) var lastCall: LassoSessionStartCall?
        func start(session name: String, call: LassoSessionStartCall) async -> LassoSessionStartResult? {
            lastCall = call
            return LassoSessionStartResult(sessionID: "fake-\(name)", isNew: true)
        }
        func id(session name: String) -> String? { "fake-\(name)" }
        func restoredValue(for varName: String, session name: String) -> LassoValue? { nil }
        func persist(_ value: LassoValue, for varName: String, session name: String) {}
        func removeVar(_ varName: String, session name: String) {}
        func end(session name: String) {}
        func abort(session name: String) {}
    }
    let provider = SessionProvider()
    var context = LassoContext(sessionProvider: provider)
    // A dynamically computed name AND a dynamic -Expires value -- both
    // invisible to the old parse-time scan, both resolve correctly now
    // since this runs at real evaluation time.
    _ = try await LassoRenderer().render(
        "[var(sessionName = 'cart')][var(expirySeconds = 3600)][session_start($sessionName, -expires=$expirySeconds, -secure=true, -domain='example.test')]",
        context: &context
    )
    #expect(provider.lastCall?.name == "cart")
    #expect(provider.lastCall?.expiresSeconds == 3600)
    #expect(provider.lastCall?.secure == true)
    #expect(provider.lastCall?.domain == "example.test")
    #expect(provider.lastCall?.useCookie == true)
}

@Test func sessionStartRecognizesTheNameKeywordForm() async throws {
    // Real corpus shape (Documentation/outstanding-compatibility-project-plans.md
    // item 7) — session_start's name spelled as -Name=, not positional,
    // across every real page using it.
    final class SessionProvider: LassoSessionProvider, @unchecked Sendable {
        private(set) var lastCall: LassoSessionStartCall?
        func start(session name: String, call: LassoSessionStartCall) async -> LassoSessionStartResult? {
            lastCall = call
            return LassoSessionStartResult(sessionID: "fake-\(name)", isNew: true)
        }
        func id(session name: String) -> String? { "fake-\(name)" }
        func restoredValue(for varName: String, session name: String) -> LassoValue? { nil }
        func persist(_ value: LassoValue, for varName: String, session name: String) {}
        func removeVar(_ varName: String, session name: String) {}
        func end(session name: String) {}
        func abort(session name: String) {}
    }
    let provider = SessionProvider()
    var context = LassoContext(sessionProvider: provider)
    _ = try await LassoRenderer().render(
        "[session_start(-Name='cart', -Expires=30, -UseCookie, -Path='/', -Domain='example.test')]",
        context: &context
    )
    #expect(provider.lastCall?.name == "cart")
    #expect(provider.lastCall?.expiresSeconds == 30)
    #expect(provider.lastCall?.path == "/")
    #expect(provider.lastCall?.domain == "example.test")
    #expect(provider.lastCall?.useCookie == true)
}

// koi.lasso -> includes/siteconfig_cookies.inc puts every Session_Start
// call inside a shared config include, not directly in the top-level page
// -- confirmed live 2026-07-18 that the retired parse-time scan found zero
// session_start calls for the whole real site because of this, silently
// disabling session tracking altogether. Evaluating session_start
// directly (this test) works regardless of how deeply nested the include
// is, since there's no separate scan needing to see through it.
@Test func sessionStartWorksFromInsideAnyDepthOfIncludeNesting() async throws {
    final class SessionProvider: LassoSessionProvider, @unchecked Sendable {
        private(set) var lastCall: LassoSessionStartCall?
        func start(session name: String, call: LassoSessionStartCall) async -> LassoSessionStartResult? {
            lastCall = call
            return LassoSessionStartResult(sessionID: "fake-\(name)", isNew: true)
        }
        func id(session name: String) -> String? { "fake-\(name)" }
        func restoredValue(for varName: String, session name: String) -> LassoValue? { nil }
        func persist(_ value: LassoValue, for varName: String, session name: String) {}
        func removeVar(_ varName: String, session name: String) {}
        func end(session name: String) {}
        func abort(session name: String) {}
    }
    let loader = MapIncludeLoader(files: [
        "includes/outer.inc": "<?lassoscript include('includes/inner.inc') ?>",
        "includes/inner.inc": "<?lassoscript session_start('cart') ?>",
    ])
    let provider = SessionProvider()
    var context = LassoContext(includeLoader: loader, sessionProvider: provider)
    _ = try await LassoRenderer().render("[include('includes/outer.inc')]", context: &context)
    #expect(provider.lastCall?.name == "cart")
}

// Real Lasso (LassoGuide): "Once a variable has been added to a session
// using the session_addVar method, its stored value will be set each time
// the session_start method is called. The variable does not need to be
// added to the session on each request, though it is safe to do so."
// Confirmed live 2026-07-18 against the real site: checkout_shipping.page.lasso
// never re-adds 'cart_id' itself (only setup_cust_cart.lasso, run from
// cart.page.lasso, ever registers it), yet real Lasso still resolves
// $cart_id there correctly -- session_start alone must restore it.
@Test func sessionStartAutoRestoresAPreviouslyAddedVariableWithoutRecallingSessionAddvar() async throws {
    final class SessionProvider: LassoSessionProvider, @unchecked Sendable {
        func start(session name: String, call: LassoSessionStartCall) async -> LassoSessionStartResult? {
            LassoSessionStartResult(sessionID: "fake-\(name)", isNew: false)
        }
        func id(session name: String) -> String? { "fake-\(name)" }
        func restoredValue(for varName: String, session name: String) -> LassoValue? {
            restoredVariables(session: name)[varName]
        }
        func restoredVariables(session name: String) -> [String: LassoValue] {
            name == "scrubs" ? ["cart_id": .string("TX04-abc123")] : [:]
        }
        func persist(_ value: LassoValue, for varName: String, session name: String) {}
        func removeVar(_ varName: String, session name: String) {}
        func end(session name: String) {}
        func abort(session name: String) {}
    }
    let provider = SessionProvider()
    var context = LassoContext(sessionProvider: provider)
    // No session_addvar('scrubs', 'cart_id') call anywhere -- session_start
    // alone must make $cart_id resolve.
    let output = try await LassoRenderer().render(
        "[session_start(-Name='scrubs')]cart_id=[$cart_id]",
        context: &context
    )
    #expect(output == "cart_id=TX04-abc123")
}

@Test func perfectBackedSessionProviderAutoRestoresVariablesOnSessionStartWithoutRecallingSessionAddvar() async throws {
    let driver = MemorySessionDriver()

    // Request 1: registers 'cart_id' via session_addvar (as setup_cust_cart.lasso
    // does, only reachable from cart.page.lasso) and finalizes.
    let firstBridge = PerfectBackedLassoSessionProvider(driver: driver, cookies: [:], remoteAddress: "", userAgent: "")
    var firstContext = LassoContext(sessionProvider: firstBridge)
    _ = try await LassoRenderer().render(
        "[session_start('scrubs')][var(cart_id = 'TX04-abc123')][session_addvar('scrubs','cart_id')]",
        context: &firstContext
    )
    let firstActions = await firstBridge.finalize()
    guard let token = firstActions.first(where: { $0.call.name == "scrubs" })?.token else {
        Issue.record("Expected a tracker token from finalize")
        return
    }

    // Request 2: a different page (like checkout_shipping.page.lasso) that
    // never calls session_addvar for 'cart_id' at all -- session_start
    // alone must still restore it, and modifying it here must still be
    // eligible to persist even without an explicit re-add.
    let secondBridge = PerfectBackedLassoSessionProvider(
        driver: driver,
        cookies: ["_LassoSessionTracker_scrubs": token],
        remoteAddress: "", userAgent: ""
    )
    var secondContext = LassoContext(sessionProvider: secondBridge)
    let secondOutput = try await LassoRenderer().render(
        "[session_start('scrubs')]cart_id=[$cart_id][var(cart_id = 'TX04-updated')]",
        context: &secondContext
    )
    #expect(secondOutput == "cart_id=TX04-abc123")
    let secondActions = await secondBridge.finalize()
    guard let secondToken = secondActions.first(where: { $0.call.name == "scrubs" })?.token else {
        Issue.record("Expected a tracker token from the second request's finalize")
        return
    }

    // Request 3: confirms the modification made in request 2 (without ever
    // calling session_addvar there) actually persisted.
    let thirdBridge = PerfectBackedLassoSessionProvider(
        driver: driver,
        cookies: ["_LassoSessionTracker_scrubs": secondToken],
        remoteAddress: "", userAgent: ""
    )
    var thirdContext = LassoContext(sessionProvider: thirdBridge)
    let thirdOutput = try await LassoRenderer().render(
        "[session_start('scrubs')]cart_id=[$cart_id]",
        context: &thirdContext
    )
    #expect(thirdOutput == "cart_id=TX04-updated")
}

@Test func sessionAddvarResolvesNameKeywordAndPositionalVarNameCorrectly() async throws {
    // Real corpus shape: Session_Addvar(-Name='cart', 'sort_by') — the
    // session name is the -Name= keyword, the var name is the (only)
    // positional argument. Before the fix, positionalValue(at: 0) would
    // have read the var name ('sort_by') as the session name, and
    // positionalValue(at: 1) would have found nothing, so varName stayed
    // empty and the whole call silently no-opped.
    final class SessionProvider: LassoSessionProvider, @unchecked Sendable {
        private(set) var persisted: [String: [String: LassoValue]] = [:]
        private var startedNames: Set<String> = []
        func start(session name: String, call: LassoSessionStartCall) async -> LassoSessionStartResult? {
            let isNew = startedNames.contains(name) == false
            startedNames.insert(name)
            return LassoSessionStartResult(sessionID: "fake-\(name)", isNew: isNew)
        }
        func id(session name: String) -> String? { startedNames.contains(name) ? "fake-\(name)" : nil }
        func restoredValue(for varName: String, session name: String) -> LassoValue? { nil }
        func persist(_ value: LassoValue, for varName: String, session name: String) {
            persisted[name, default: [:]][varName] = value
        }
        func removeVar(_ varName: String, session name: String) {}
        func end(session name: String) {}
        func abort(session name: String) {}
    }

    let provider = SessionProvider()
    var context = LassoContext(sessionProvider: provider)
    _ = try await LassoRenderer().render(
        "[session_start(-Name='cart')][var(sort_by = 'newest')][session_addvar(-Name='cart', 'sort_by')]",
        context: &context
    )
    #expect(provider.persisted["cart"]?["sort_by"]?.outputString == "newest")
    #expect(provider.persisted["sort_by"] == nil, "the var name must not be mistaken for the session name")
}

@Test func sessionEndAndSessionIdResolveTheNameKeywordFormWithNoVarNameArgument() async throws {
    // Real corpus shapes: Session_ID(-Name='...') (used as an expression,
    // e.g. embedded in a redirect URL) and Session_End(-Name='...') —
    // keyword-only, no second (var-name) argument at all.
    final class SessionProvider: LassoSessionProvider, @unchecked Sendable {
        private(set) var endedNames: Set<String> = []
        private var startedNames: Set<String> = []
        func start(session name: String, call: LassoSessionStartCall) async -> LassoSessionStartResult? {
            startedNames.insert(name)
            return LassoSessionStartResult(sessionID: "fake-\(name)", isNew: true)
        }
        func id(session name: String) -> String? { startedNames.contains(name) ? "fake-\(name)" : nil }
        func restoredValue(for varName: String, session name: String) -> LassoValue? { nil }
        func persist(_ value: LassoValue, for varName: String, session name: String) {}
        func removeVar(_ varName: String, session name: String) {}
        func end(session name: String) { endedNames.insert(name) }
        func abort(session name: String) {}
    }

    let provider = SessionProvider()
    var context = LassoContext(sessionProvider: provider)
    let output = try await LassoRenderer().render(
        "[session_start(-Name='cart')][Session_ID(-Name='cart')]",
        context: &context
    )
    #expect(output == "fake-cart")

    _ = try await LassoRenderer().render("[session_end(-Name='cart')]", context: &context)
    #expect(provider.endedNames.contains("cart"))
}

@Test func sessionRemoveVarAbortAndResultResolveTheNameKeywordForm() async throws {
    // No direct real corpus shape found for these three (unlike
    // session_start/session_addvar/session_id/session_end above) — fixed
    // anyway via the same shared resolver rather than leaving an
    // arbitrary split between natives that recognize -Name= and ones that
    // don't. See Documentation/outstanding-compatibility-project-plans.md
    // item 7.
    final class SessionProvider: LassoSessionProvider, @unchecked Sendable {
        private(set) var persisted: [String: [String: LassoValue]] = [:]
        private(set) var abortedNames: Set<String> = []
        func start(session name: String, call: LassoSessionStartCall) async -> LassoSessionStartResult? {
            LassoSessionStartResult(sessionID: "fake-\(name)", isNew: true)
        }
        func id(session name: String) -> String? { "fake-\(name)" }
        func restoredValue(for varName: String, session name: String) -> LassoValue? { nil }
        func persist(_ value: LassoValue, for varName: String, session name: String) {
            persisted[name, default: [:]][varName] = value
        }
        func removeVar(_ varName: String, session name: String) {
            persisted[name]?[varName] = nil
        }
        func end(session name: String) {}
        func abort(session name: String) { abortedNames.insert(name) }
    }

    let provider = SessionProvider()
    var context = LassoContext(sessionProvider: provider)
    _ = try await LassoRenderer().render(
        "[session_start(-Name='cart')][var(a = 'x')][session_addvar(-Name='cart', 'a')]" +
            "[session_removevar(-Name='cart', 'a')]",
        context: &context
    )
    #expect(provider.persisted["cart"]?["a"] == nil)

    _ = try await LassoRenderer().render("[session_abort(-Name='cart')]", context: &context)
    #expect(provider.abortedNames.contains("cart"))

    let resultOutput = try await LassoRenderer().render(
        "[session_start(-Name='fresh')][session_result(-Name='fresh')->new]",
        context: &context
    )
    #expect(resultOutput == "true")
}

@Test func perfectBackedSessionProviderPersistsVariablesAcrossTwoRequestsViaMemoryDriver() async throws {
    let driver = MemorySessionDriver()

    // Request 1: new session, register+set a variable, finalize (saves it).
    let firstBridge = PerfectBackedLassoSessionProvider(driver: driver, cookies: [:], remoteAddress: "", userAgent: "")
    var firstContext = LassoContext(sessionProvider: firstBridge)
    let firstOutput = try await LassoRenderer().render(
        "[session_start('cart')][var(total = 3)][session_addvar('cart','total')][total]",
        context: &firstContext
    )
    #expect(firstOutput == "3")
    let firstActions = await firstBridge.finalize()
    guard let token = firstActions.first(where: { $0.call.name == "cart" })?.token else {
        Issue.record("Expected a tracker token from finalize")
        return
    }

    // Request 2: resumes via the cookie the first request would have set —
    // the previously-persisted variable should come back without the page
    // setting it again.
    let secondBridge = PerfectBackedLassoSessionProvider(
        driver: driver,
        cookies: ["_LassoSessionTracker_cart": token],
        remoteAddress: "", userAgent: ""
    )
    var secondContext = LassoContext(sessionProvider: secondBridge)
    let secondOutput = try await LassoRenderer().render(
        "[session_start('cart')][session_addvar('cart','total')][total]",
        context: &secondContext
    )
    #expect(secondOutput == "3")
}

@Test func perfectBackedSessionProviderEndDestroysSessionAndClearsCookie() async throws {
    let driver = MemorySessionDriver()

    let bridge = PerfectBackedLassoSessionProvider(driver: driver, cookies: [:], remoteAddress: "", userAgent: "")
    var context = LassoContext(sessionProvider: bridge)
    _ = try await LassoRenderer().render("[session_start('cart')][session_end('cart')]", context: &context)
    let actions = await bridge.finalize()
    let action = actions.first(where: { $0.call.name == "cart" })
    #expect(action?.shouldClearCookie == true)
    #expect(action?.token == nil)
}

@Test func protectCatchesRecoverableErrorAndSetsCurrentError() async throws {
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
    let output = try await LassoRenderer().render(
        "before-[protect]during-[fail_with_db_error]-unreached[/protect]-after-[error_currenterror]-[error_currenterror(-errorcode)]",
        context: &context
    )
    #expect(output == "before--after-Add failed-42")
}

@Test func protectDoesNotCatchReturnOrFatalErrors() async throws {
    // return/abort ride the existing returnSignal short-circuit, not a
    // thrown error, so protect's do/catch never even sees them — but this
    // is worth a real regression test rather than trusting the mechanism
    // description. Separately, genuine fatal errors (LassoRuntimeError)
    // must stay fatal — protect only catches LassoRecoverableError.
    var returnContext = LassoContext()
    let returnOutput = try await LassoRenderer().render(
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
    await #expect(throws: LassoRuntimeError.unknownFunction("totally_undefined_native")) {
        _ = try await LassoRenderer().render(
            "[protect]during-[totally_undefined_native()][/protect]-after",
            context: &fatalContext
        )
    }
}

@Test func errorCurrentErrorDefaultsToNoErrorAndInlineFramesUpdateIt() async throws {
    // Milestone 3/4: a fresh context starts at real Lasso's "No Error"
    // state, and pushing an inline frame (the mechanism every inline
    // action already goes through) updates context.currentError from the
    // frame's own error state — the wiring inline-write-raw-sql-plan's
    // executor work will populate with real connector failures later.
    var context = LassoContext()
    let defaultOutput = try await LassoRenderer().render(
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

// MARK: - web_response->include*, includeBytes, sendFile (item 8)
//
// See Documentation/web-response-include-plan.md. Grounded in the
// documented Lasso 8.5/9 contract, not real corpus evidence — a direct
// grep of the real site found zero usages of any of these members, so
// there's no observed shape to mirror here (unlike most other test groups
// in this file). Every judgment call the implementation makes (the void
// return on a repeat includeOnce call, includes()'s include-family-only
// scope, file_serve/file_stream's root confinement) has its own test named
// explicitly as a judgment call, not silently assumed correct.

/// Shared fixture for the tests below: an in-memory, dictionary-backed
/// `LassoIncludeLoader` that also counts loads per path (for dedup
/// assertions) and lets a test override the raw bytes returned for a path
/// independently of its text content (for the includeBytes lossy-decode
/// test, which needs genuinely invalid UTF-8).
private final class MapIncludeLoader: LassoIncludeLoader, @unchecked Sendable {
    private(set) var loadCounts: [String: Int] = [:]
    var files: [String: String]
    var byteOverrides: [String: Data] = [:]

    init(files: [String: String]) {
        self.files = files
    }

    func loadInclude(path: String, from includingPath: String?) throws -> String {
        loadCounts[path, default: 0] += 1
        guard let content = files[path] else {
            throw LassoFileSystemIncludeError.fileNotFound(path)
        }
        return content
    }

    func loadIncludeBytes(path: String, from includingPath: String?) throws -> Data {
        if let override = byteOverrides[path] { return override }
        return Data(try loadInclude(path: path, from: includingPath).utf8)
    }
}

@Test func webResponseIncludeRendersFileContentAsExpressionOutput() async throws {
    let loader = MapIncludeLoader(files: ["header.lasso": "<h1>Hi</h1>"])
    var context = LassoContext(includeLoader: loader)
    let output = try await LassoRenderer().render(
        "<?lasso web_response->include('header.lasso') ?>",
        context: &context
    )
    #expect(output == "<h1>Hi</h1>")
}

@Test func includeOnceSecondCallReturnsVoidPendingDocConfirmation() async throws {
    // No confirmed documented return value exists in either reference
    // source for a repeat includeOnce call — defaulting to `.void`,
    // matching includeLibraryOnce's documented "no value" and this
    // codebase's void-on-no-op convention elsewhere. A judgment call, not
    // a confirmed contract.
    let loader = MapIncludeLoader(files: ["header.lasso": "HI"])
    var context = LassoContext(includeLoader: loader)
    let output = try await LassoRenderer().render(
        "[web_response->includeOnce('header.lasso')]|[web_response->includeOnce('header.lasso')]",
        context: &context
    )
    #expect(output == "HI|")
    #expect(loader.loadCounts["header.lasso"] == 1)
}

@Test func includeLibraryReexecutesEveryCallWithNoDedup() async throws {
    let loader = MapIncludeLoader(files: ["lib.lasso": "x"])
    var context = LassoContext(includeLoader: loader)
    _ = try await LassoRenderer().render(
        "<?lasso web_response->includeLibrary('lib.lasso') web_response->includeLibrary('lib.lasso') ?>",
        context: &context
    )
    #expect(loader.loadCounts["lib.lasso"] == 2)
}

@Test func includeLibraryOnceDedupesWithinOneRenderLikeTheFreeLibraryTag() async throws {
    let loader = MapIncludeLoader(files: ["lib.lasso": "x"])
    var context = LassoContext(includeLoader: loader)
    _ = try await LassoRenderer().render(
        "<?lasso web_response->includeLibraryOnce('lib.lasso') web_response->includeLibraryOnce('lib.lasso') ?>",
        context: &context
    )
    #expect(loader.loadCounts["lib.lasso"] == 1)
}

@Test func includeLibraryDetectsSelfReferentialCycleInsteadOfCrashing() async throws {
    // Regression for a stack-overflow found in code review: unlike the
    // free `library(...)` tag (always once:true, protected by
    // loadedLibraries dedup even on self-reference), includeLibrary's
    // once:false call has no dedup to fall back on — without its own
    // independent libraryStack guard, a self-referential includeLibrary
    // chain would recurse through native Swift calls unboundedly and trap
    // the whole process, not just fail this one request.
    let loader = MapIncludeLoader(files: ["lib.lasso": "<?lasso web_response->includeLibrary('lib.lasso') ?>"])
    var context = LassoContext(includeLoader: loader)
    await #expect(throws: LassoRuntimeError.includeCycle("lib.lasso")) {
        _ = try await LassoRenderer().render("<?lasso web_response->includeLibrary('lib.lasso') ?>", context: &context)
    }
}

@Test func includeLibraryEnforcesDepthLimitOnChainedRecursion() async throws {
    var files: [String: String] = [:]
    for i in 0..<40 {
        files["g\(i).lasso"] = "<?lasso web_response->includeLibrary('g\(i + 1).lasso') ?>"
    }
    let loader = MapIncludeLoader(files: files)
    var context = LassoContext(includeLoader: loader)
    await #expect(throws: LassoRuntimeError.includeDepthExceeded) {
        _ = try await LassoRenderer().render("<?lasso web_response->includeLibrary('g0.lasso') ?>", context: &context)
    }
}

@Test func webResponseIncludeDetectsSelfReferentialCycle() async throws {
    let loader = MapIncludeLoader(files: ["a.lasso": "<?lasso web_response->include('a.lasso') ?>"])
    var context = LassoContext(includeLoader: loader)
    await #expect(throws: LassoRuntimeError.includeCycle("a.lasso")) {
        _ = try await LassoRenderer().render("<?lasso web_response->include('a.lasso') ?>", context: &context)
    }
}

@Test func webResponseIncludeEnforcesDepthLimit() async throws {
    var files: [String: String] = [:]
    for i in 0..<40 {
        files["f\(i).lasso"] = i < 39 ? "<?lasso web_response->include('f\(i + 1).lasso') ?>" : "leaf"
    }
    let loader = MapIncludeLoader(files: files)
    var context = LassoContext(includeLoader: loader)
    await #expect(throws: LassoRuntimeError.includeDepthExceeded) {
        _ = try await LassoRenderer().render("<?lasso web_response->include('f0.lasso') ?>", context: &context)
    }
}

@Test func includesMethodReflectsLiveNestingStackDuringNestedInclude() async throws {
    let loader = MapIncludeLoader(files: [
        "outer.lasso": "[web_response->includes()]|[web_response->include('inner.lasso')]",
        "inner.lasso": "[web_response->includes()]",
    ])
    var context = LassoContext(includeLoader: loader)
    let output = try await LassoRenderer().render(
        "before:[web_response->includes()]|[web_response->include('outer.lasso')]|after:[web_response->includes()]",
        context: &context
    )
    // Empty before/after the include (top-level, nothing executing);
    // "outer.lasso" while outer runs; "outer.lassoinner.lasso" (a
    // one-element-per-frame array, .outputString joins with no
    // separator) while inner runs nested inside it.
    #expect(output == "before:|outer.lasso|outer.lassoinner.lasso|after:")
}

@Test func includesMethodDoesNotReflectLibraryCallsPerDocumentedScope() async throws {
    // includes() is scoped to the live include-family nesting stack only:
    // only include/includeOnce push onto includeStack today (library calls
    // never did, matching the free library(...) tag's pre-existing
    // behavior). A deliberate, flagged judgment call — no confirmed doc
    // answer either way in LassoGuide 9.3.
    let loader = MapIncludeLoader(files: ["lib.lasso": "[web_response->includes()]"])
    var context = LassoContext(includeLoader: loader)
    let output = try await LassoRenderer().render(
        "[web_response->includeLibrary('lib.lasso')]",
        context: &context
    )
    #expect(output == "")
}

@Test func includeBytesRoundTripsTextContent() async throws {
    let loader = MapIncludeLoader(files: ["data.txt": "hello bytes"])
    var context = LassoContext(includeLoader: loader)
    let output = try await LassoRenderer().render(
        "[web_response->includeBytes('data.txt')]",
        context: &context
    )
    #expect(output == "hello bytes")
}

@Test func includeBytesLossyDecodesInvalidUTF8InsteadOfThrowing() async throws {
    // Documented limitation, not a crash: no LassoValue case models binary
    // data yet (zero corpus evidence to size one correctly), so a byte
    // sequence that isn't valid UTF-8 decodes lossily (U+FFFD replacement
    // characters) rather than failing the render.
    let loader = MapIncludeLoader(files: ["blob.bin": ""])
    loader.byteOverrides["blob.bin"] = Data([0xFF, 0xFE, 0x41, 0x42])
    var context = LassoContext(includeLoader: loader)
    let output = try await LassoRenderer().render(
        "[web_response->includeBytes('blob.bin')]",
        context: &context
    )
    #expect(output.contains("AB"))
    #expect(output.contains("\u{FFFD}"))
}

@Test func loadIncludeBytesDefaultExtensionThrowsForLegacyLoaders() async throws {
    // Proves the default protocol-extension claim: a loader written before
    // includeBytes existed (only implementing loadInclude) doesn't need to
    // change, and correctly surfaces includeNotConfigured rather than a
    // missing-witness compile error or a silent wrong answer.
    struct LegacyLoader: LassoIncludeLoader {
        func loadInclude(path: String, from includingPath: String?) throws -> String { "ok" }
    }
    var context = LassoContext(includeLoader: LegacyLoader())
    await #expect(throws: LassoRuntimeError.includeNotConfigured) {
        _ = try await LassoRenderer().render("[web_response->includeBytes('x.lasso')]", context: &context)
    }
}

@Test func webResponseIncludeRejectsPathEscapingRootLikeTheFreeTag() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("lasso-webresponse-include-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let loader = try LassoFileSystemIncludeLoader(root: root)
    var context = LassoContext(includeLoader: loader)
    await #expect(throws: LassoFileSystemIncludeError.pathOutsideRoot("../../outside.lasso")) {
        _ = try await LassoRenderer().render(
            "<?lasso web_response->include('../../outside.lasso') ?>",
            context: &context
        )
    }
}

@Test func webResponseIncludeLibraryRejectsPathEscapingRoot() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("lasso-webresponse-library-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let loader = try LassoFileSystemIncludeLoader(root: root)
    var context = LassoContext(includeLoader: loader)
    await #expect(throws: LassoFileSystemIncludeError.pathOutsideRoot("../../outside.lasso")) {
        _ = try await LassoRenderer().render(
            "<?lasso web_response->includeLibrary('../../outside.lasso') ?>",
            context: &context
        )
    }
}

@Test func includeBytesRejectsPathEscapingRootUsingTheSameConfinementAsLoadInclude() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("lasso-webresponse-bytes-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let loader = try LassoFileSystemIncludeLoader(root: root)
    var context = LassoContext(includeLoader: loader)
    await #expect(throws: LassoFileSystemIncludeError.pathOutsideRoot("../../outside.lasso")) {
        _ = try await LassoRenderer().render(
            "[web_response->includeBytes('../../outside.lasso')]",
            context: &context
        )
    }
}

@Test func sendFileRecordsDataPayloadHeadersAndAbortsRendering() async throws {
    final class RecordingFileServeSink: LassoResponseSink, @unchecked Sendable {
        private(set) var fileServeRequest: LassoFileServeRequest?
        func setStatus(_ status: Int) throws {}
        func redirect(to url: String) throws {}
        func setCookie(name: String, value: String) throws {}
        func serveFile(_ request: LassoFileServeRequest) throws { fileServeRequest = request }
    }

    let sink = RecordingFileServeSink()
    var context = LassoContext(responseSink: sink)
    let output = try await LassoRenderer().render(
        "BEFORE<?lasso web_response->sendFile('file contents', 'report.csv', -type='text/csv', -disposition='inline') ?>AFTER",
        context: &context
    )
    // Rides the same return-signal short-circuit as abort() — AFTER never
    // runs.
    #expect(output == "BEFORE")

    guard case let .data(data)? = sink.fileServeRequest?.source else {
        Issue.record("Expected a .data source")
        return
    }
    #expect(String(decoding: data, as: UTF8.self) == "file contents")
    #expect(sink.fileServeRequest?.fileName == "report.csv")
    #expect(sink.fileServeRequest?.contentType == "text/csv")
    #expect(sink.fileServeRequest?.disposition == "inline")
}

@Test func sendFileDefaultsDispositionToAttachmentWithNoNameOrType() async throws {
    // Matches sendFile's real documented -disposition default
    // ('attachment') even when no name/type override is given.
    final class RecordingFileServeSink: LassoResponseSink, @unchecked Sendable {
        private(set) var fileServeRequest: LassoFileServeRequest?
        func setStatus(_ status: Int) throws {}
        func redirect(to url: String) throws {}
        func setCookie(name: String, value: String) throws {}
        func serveFile(_ request: LassoFileServeRequest) throws { fileServeRequest = request }
    }

    let sink = RecordingFileServeSink()
    var context = LassoContext(responseSink: sink)
    _ = try await LassoRenderer().render("<?lasso web_response->sendFile('abc') ?>", context: &context)

    #expect(sink.fileServeRequest?.disposition == "attachment")
    #expect(sink.fileServeRequest?.fileName == nil)
    #expect(sink.fileServeRequest?.contentType == nil)
}

@Test func sendFileDefaultExtensionIsANoOpForLegacySinksButStillAborts() async throws {
    // Proves the default protocol-extension claim for serveFile: a sink
    // written before file serving existed (never overriding serveFile)
    // doesn't need to change, and sendFile still aborts rendering even
    // though there's nowhere for the payload to land.
    struct LegacySink: LassoResponseSink {
        func setStatus(_ status: Int) throws {}
        func redirect(to url: String) throws {}
        func setCookie(name: String, value: String) throws {}
    }
    var context = LassoContext(responseSink: LegacySink())
    let output = try await LassoRenderer().render(
        "BEFORE<?lasso web_response->sendFile('x') ?>AFTER",
        context: &context
    )
    #expect(output == "BEFORE")
}

@Test func fileServeAndFileStreamRecordPathSourceAbortAndOmitDispositionByDefault() async throws {
    // file_serve/file_stream are implemented as aliases of one identical
    // registration (no confirmed documented behavioral distinction found
    // between them for this adapter's purposes) — both must behave
    // identically here. Unlike sendFile, neither has a documented
    // disposition concept, so disposition/fileName stay nil by default
    // (checked in main.swift's response-building: nil means "don't emit
    // Content-Disposition at all").
    final class RecordingFileServeSink: LassoResponseSink, @unchecked Sendable {
        private(set) var fileServeRequest: LassoFileServeRequest?
        func setStatus(_ status: Int) throws {}
        func redirect(to url: String) throws {}
        func setCookie(name: String, value: String) throws {}
        func serveFile(_ request: LassoFileServeRequest) throws { fileServeRequest = request }
    }

    for tag in ["file_serve", "file_stream"] {
        let sink = RecordingFileServeSink()
        var context = LassoContext(responseSink: sink)
        let output = try await LassoRenderer().render(
            "BEFORE<?lasso \(tag)(-File='downloads/report.pdf', -Type='application/pdf') ?>AFTER",
            context: &context
        )
        #expect(output == "BEFORE", "\(tag) should abort rendering like sendFile/abort")

        guard case let .path(path)? = sink.fileServeRequest?.source else {
            Issue.record("Expected a .path source for \(tag)")
            continue
        }
        #expect(path == "downloads/report.pdf")
        #expect(sink.fileServeRequest?.contentType == "application/pdf")
        #expect(sink.fileServeRequest?.disposition == nil, "\(tag) should not force a Content-Disposition by default")
        #expect(sink.fileServeRequest?.fileName == nil)
    }
}

@Test func fileServeAcceptsAPositionalPathArgument() async throws {
    final class RecordingFileServeSink: LassoResponseSink, @unchecked Sendable {
        private(set) var fileServeRequest: LassoFileServeRequest?
        func setStatus(_ status: Int) throws {}
        func redirect(to url: String) throws {}
        func setCookie(name: String, value: String) throws {}
        func serveFile(_ request: LassoFileServeRequest) throws { fileServeRequest = request }
    }

    let sink = RecordingFileServeSink()
    var context = LassoContext(responseSink: sink)
    _ = try await LassoRenderer().render("<?lasso file_serve('downloads/report.pdf') ?>", context: &context)

    guard case let .path(path)? = sink.fileServeRequest?.source else {
        Issue.record("Expected a .path source")
        return
    }
    #expect(path == "downloads/report.pdf")
}

@Test func ieConditionalCommentsDoNotSwallowPageBodyAsABareIfBlock() async throws {
    // HTML5-Boilerplate-style IE conditional comments (found in real corpus
    // templates, e.g. templates/koi/master.template.lasso) are just inert
    // HTML comments to a real browser, but the literal text `[if IE 8]`
    // inside them used to be misparsed: no parens means ExpressionParser
    // can't produce a `.call`, so it fell back to the bare identifier `if`
    // — and `if` used to be accepted as a valid zero-argument block opener,
    // silently swallowing everything until an unrelated `[/if]` closed it.
    var context = LassoContext(globals: ["marker": .string("real content")])
    let source = """
    <!--[if IE 8]> <html class="ie8"> <![endif]-->
    <!--[if !IE]> --><html><!-- <![endif]-->
    [$marker]
    """
    let output = try await LassoRenderer().render(source, context: &context)
    #expect(output.contains("real content"), "Page content after the IE conditional comments was swallowed: \(output)")
}

@Test func bareIfWithNoParensIsNotTreatedAsAConditionlessBlock() async throws {
    // A bare `[if]`/`[if somebareword]` (no parens, no real condition) has
    // no sensible Lasso meaning and must not become a real if-block opener
    // — only `if(...)`/`if:(...)` (a genuine condition) should. Otherwise
    // any literal text containing `[if ...]`-shaped brackets anywhere (not
    // just inside HTML comments) would silently swallow real page content
    // up to an unrelated `[/if]`.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        "before [if bareword] middle [/if] after",
        context: &context
    )
    #expect(output.contains("before"))
    #expect(output.contains("after"))

    var realConditionContext = LassoContext()
    let realConditionOutput = try await LassoRenderer().render(
        "[if(true)]yes[else]no[/if]",
        context: &realConditionContext
    )
    #expect(realConditionOutput == "yes", "Real if(...) with parens must still work as a genuine block")
}

@Test func bareTernaryStatementGuardWithNoElseBranchAssignsOnlyWhenTrue() async throws {
    // Lasso 8's bare statement-guard ternary — `condition ? statement`, no
    // `|` else-branch at all — is a separate dialect from the documented
    // value form (`condition ? whenTrue | whenFalse`). Real corpus:
    // pages/subcats.page.lasso's `[string($cid) != '' ? $bottom_cat=$cid]`,
    // repeated for cid/cid2.../cid8. Previously this silently swallowed
    // whatever text followed (ExpressionParser kept trying to parse a
    // whenFalse that was never there), producing an empty
    // `unsupportedExpression("")` — confirmed live via
    // koi.lasso?cid=...&page=subcats.
    var trueContext = LassoContext()
    let trueOutput = try await LassoRenderer().render(
        "[var(cid::string='CATEGORY123')][string($cid) != '' ? var(bottom_cat=$cid)][$bottom_cat] after",
        context: &trueContext
    )
    #expect(trueOutput.contains("CATEGORY123"), "Guard's statement should have run when the condition is true")
    #expect(trueOutput.contains("after"), "Content after the guard must still render, not be swallowed")

    var falseContext = LassoContext()
    let falseOutput = try await LassoRenderer().render(
        "[var(cid::string='')][string($cid) != '' ? var(bottom_cat='should not run')] after",
        context: &falseContext
    )
    #expect(falseOutput.contains("should not run") == false, "Guard's statement must not run when the condition is false")
    #expect(falseOutput.contains("after"), "Content after a false guard must still render")
}

@Test func stringReplaceMutatesTheInvocantInPlaceAndProducesNoOutputAsABareStatement() async throws {
    // string->replace(find, replaceWith) mutates its invocant in place —
    // like array/map ->insert — rather than merely computing a new
    // string, when the base is a real variable and the call is the whole
    // bare statement. Real corpus: pages/subcats3.page.lasso's
    // `[$uniform_restrictions->(Replace('!','<br>'))]` (bare, no echo)
    // followed later by a separate `[$uniform_restrictions]` reference —
    // confirmed live against thekoiwarehouse.com/koi.lasso?page=subcats2,
    // whose master.template.lasso-shared `[$meta_keywords->(Replace('-',','))]`
    // and pages/thumbs2.page.lasso's 5-step `$cleaned_product_name`
    // cleanup chain produce zero visible output on production — echoing
    // the mutated value here (the old, unverified assumption) instead
    // printed every intermediate step's string as stray page text.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        "[var(msg::string='no!smoking!allowed')][$msg->(Replace('!','<br>'))][$msg]",
        context: &context
    )
    #expect(output == "no<br>smoking<br>allowed")
}

@Test func stringReplaceOnANonVariableBaseStillReturnsItsComputedValue() async throws {
    // The self-mutating write-back only applies to a real *variable*
    // base — a string literal (or any other non-assignable expression)
    // can't be written back to, so ->replace on one still just computes
    // and returns the transformed value normally. Covered separately from
    // `wrappedMemberCallWithNestedCallConsumesBothClosingParens`, which
    // exercises the same shape for a different reason (paren-consumption).
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        "[('no!smoking!allowed')->(Replace('!','<br>'))]",
        context: &context
    )
    #expect(output == "no<br>smoking<br>allowed")
}

@Test func stringReplaceNestedInsideALargerExpressionStillReadsItsComputedValue() async throws {
    // The self-mutating write-back only fires when the ->replace call
    // IS the whole top-level statement (`Renderer.renderExpression` ->
    // `Evaluator.evaluateStatement`) — nested inside a larger expression,
    // it must still behave as a plain, value-returning call. Real corpus:
    // _begin.lasso / components/_begin_tags.inc's
    // `#out >> '-' ? #out = '-' + #out->replace('-','')` reads ->replace's
    // result as part of the concatenation; voiding it here would silently
    // collapse the expression to `'-' + ''`.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        "[var(out::string='--leading')][$out = '-' + $out->replace('-','')][$out]",
        context: &context
    )
    #expect(output == "-leading")
}

@Test func stringAppendMutatesTheInvocantInPlaceAndProducesNoOutputAsABareStatement() async throws {
    // string->append(value) mutates its invocant in place, same as
    // ->replace above — when the base is a real variable and the call is
    // the whole bare statement. Real corpus: LassoStartup/hash_test.lasso's
    // scrubs_hash custom tag, `#hash->append('\r\n')` right after
    // computing an Encrypt_HMAC hash — confirmed live 2026-07-18 against
    // koi.scrubs.test's login/checkout flow.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        "[var(msg::string='hello')][$msg->append(' world')][$msg]",
        context: &context
    )
    #expect(output == "hello world")
}

@Test func stringAppendOnANonVariableBaseStillReturnsItsComputedValue() async throws {
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        "[('hello')->append(' world')]",
        context: &context
    )
    #expect(output == "hello world")
}

@Test func stringAppendWithNoArgumentAppendsAnEmptyStringAndProducesNoOutput() async throws {
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        "[var(msg::string='hello')][$msg->append()][$msg]",
        context: &context
    )
    #expect(output == "hello")
}

@Test func stringTrimMutatesTheInvocantInPlaceAndProducesNoOutputAsABareStatement() async throws {
    // string->trim mutates its invocant in place, same as ->append/->replace
    // above — Lasso 8.5 Language Guide: "Removes all white space from the
    // start and end of the string. Modifies the string in place and
    // returns no value." Real corpus: login_check_top.lasso's bare
    // `$email->(trim)` — confirmed live 2026-07-18 against koi.scrubs.test's
    // login flow, immediately after the Valid_Email fix.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        "[var(email::string='  test@example.com  ')][$email->(trim)][$email]",
        context: &context
    )
    #expect(output == "test@example.com")
}

@Test func stringTrimOnANonVariableBaseStillReturnsItsComputedValue() async throws {
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        "[('  hello  ')->trim]",
        context: &context
    )
    #expect(output == "hello")
}

@Test func stringTrimRemovesTabsAndNewlinesAsWellAsSpaces() async throws {
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        "[var(padded::string='\\t\\r\\n hello \\n\\t')][$padded->(trim)][$padded]",
        context: &context
    )
    #expect(output == "hello")
}

@Test func stringSubstringReturnsAOneBasedRangeMatchingTheDocsWorkedExample() async throws {
    // LassoGuide's own worked example: 'The String'->sub(5, 6) == 'String'
    // -- confirms 1-based start (position 5 is the 5th character).
    var context = LassoContext()
    let output = try await LassoRenderer().render("[('The String')->sub(5, 6)]", context: &context)
    #expect(output == "String")
}

@Test func stringSubstringWithOnlyAStartReturnsTheRestOfTheString() async throws {
    var context = LassoContext()
    let output = try await LassoRenderer().render("[('Hello World')->substring(7)]", context: &context)
    #expect(output == "World")
}

@Test func stringSubstringMasksACreditCardNumberLikeTheRealCorpusDoes() async throws {
    // Exact real-corpus shape: pages/checkout.page.lasso masks a card
    // number via string(field('card_number'))->(Substring: 1, 1) to test
    // the leading digit, and ->(Substring: 13, 4) for the last 4 digits
    // -- both via the older arrow-paren call syntax. Previously crashed
    // with unsupportedExpression("Member substring") since .string had no
    // "substring"/"sub" case at all.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        "[var(card::string = '4111111111111111')]" +
        "[$card->(Substring: 1, 1)]|[$card->(Substring: 13, 4)]",
        context: &context
    )
    #expect(output == "4|1111")
}

@Test func pairConstructorSupportsAllFourRealLassoForms() async throws {
    // LassoGuide, "Collections": pair() -> both null; pair(anotherPair) ->
    // copies first/second; pair(value, value) -> two positional elements;
    // pair(value=value) -> key-value/named-assignment form. Real corpus:
    // includes/efs_process.lasso's `Pair('x_Login'=#x_login)` and 20+
    // sibling calls -- previously unregistered entirely, so every one
    // threw unknownFunction("Pair") immediately.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        """
        [pair(3, 4)->first]=[pair(3, 4)->second]|\
        [pair('x_login'='abc')->first]=[pair('x_login'='abc')->second]|\
        [var(original = pair('a', 'b'))][pair($original)->first]=[pair($original)->second]|\
        [pair()->first]
        """,
        context: &context
    )
    #expect(output == "3=4|x_login=abc|a=b|")
}

// MARK: - include_url (mocked network layer)

/// Captures the outgoing request and returns a canned response — same
/// pattern as `Perfect-FileMaker`'s own `MockURLProtocol`.
private final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var requestHandler: (@Sendable (URLRequest, Data?) throws -> (HTTPURLResponse, Data))?
    nonisolated(unsafe) static var lastRequest: URLRequest?
    nonisolated(unsafe) static var lastBody: Data?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body = Self.bodyData(from: request)
        Self.lastRequest = request
        Self.lastBody = body
        guard let handler = Self.requestHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try handler(request, body)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    static func bodyData(from request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}

private func withMockedIncludeURL<T>(
    handler: @escaping @Sendable (URLRequest, Data?) throws -> (HTTPURLResponse, Data),
    _ body: () async throws -> T
) async throws -> T {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [MockURLProtocol.self]
    MockURLProtocol.requestHandler = handler
    MockURLProtocol.lastRequest = nil
    MockURLProtocol.lastBody = nil
    LassoIncludeURL.testSessionOverride = URLSession(configuration: config)
    defer { LassoIncludeURL.testSessionOverride = nil }
    return try await body()
}

private func okResponse(_ body: String, headers: [String: String]? = nil) -> @Sendable (URLRequest, Data?) -> (HTTPURLResponse, Data) {
    { req, _ in
        let http = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: headers)!
        return (http, Data(body.utf8))
    }
}

@Suite(.serialized)
struct IncludeURLTests {
    @Test func getRequestReturnsBodyAsABytesObjectByDefault() async throws {
        // Default return is a `bytes` object (LassoGuide: "By default,
        // this method returns the HTML body result... as a bytes object"),
        // not a string -- confirmed via its bare-output fallback, matching
        // how every other bytes-returning native in this codebase is
        // tested (e.g. decodeBase64), since `->size` is deliberately
        // unimplemented for `bytes` (see BytesType.swift).
        try await withMockedIncludeURL(handler: okResponse("hello")) {
            var context = LassoContext()
            let output = try await LassoRenderer().render("[include_url('http://mock.example/')]", context: &context)
            #expect(output == "hello")
        }
    }

    @Test func stringFlagReturnsAStringNotABytesObject() async throws {
        try await withMockedIncludeURL(handler: okResponse("hello")) {
            var context = LassoContext()
            let output = try await LassoRenderer().render(
                "[include_url('http://mock.example/', -string)]",
                context: &context
            )
            #expect(output == "hello")
        }
    }

    @Test func postParamsArrayOfPairsFormEncodesTheBody() async throws {
        // Exact real-corpus shape: includes/efs_process.lasso builds its
        // entire gateway request as an array of Pair(...) calls.
        try await withMockedIncludeURL(handler: okResponse("ok")) {
            var context = LassoContext()
            _ = try await LassoRenderer().render(
                """
                [include_url('http://mock.example/gateway',
                    -postParams=array(Pair('x_login'='4h5jXQ57kAK'), Pair('x_amount'='19.99'), Pair('note'='a b+c')))]
                """,
                context: &context
            )
            let body = MockURLProtocol.lastBody.map { String(decoding: $0, as: UTF8.self) }
            #expect(body == "x_login=4h5jXQ57kAK&x_amount=19.99&note=a+b%2Bc")
            #expect(MockURLProtocol.lastRequest?.httpMethod == "POST")
            #expect(MockURLProtocol.lastRequest?.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
        }
    }

    @Test func sendMimeHeadersSetsCustomRequestHeaders() async throws {
        try await withMockedIncludeURL(handler: okResponse("ok")) {
            var context = LassoContext()
            _ = try await LassoRenderer().render(
                "[include_url('http://mock.example/', -sendMimeHeaders=array(Pair('X-Custom'='abc')))]",
                context: &context
            )
            #expect(MockURLProtocol.lastRequest?.value(forHTTPHeaderField: "X-Custom") == "abc")
        }
    }

    @Test func retrieveMimeHeadersStoresResponseHeadersIntoTheNamedVariable() async throws {
        try await withMockedIncludeURL(handler: okResponse("ok", headers: ["ReplyStatus": "yes"])) {
            var context = LassoContext()
            let output = try await LassoRenderer().render(
                "[var(x = include_url('http://mock.example/', -retrieveMimeHeaders='resp_headers'))][$resp_headers->replystatus]",
                context: &context
            )
            #expect(output == "yes")
        }
    }

    @Test func noDataReturnsVoidInsteadOfTheResponseBody() async throws {
        try await withMockedIncludeURL(handler: okResponse("should not appear")) {
            var context = LassoContext()
            let output = try await LassoRenderer().render(
                "before[include_url('http://mock.example/', -noData)]after",
                context: &context
            )
            #expect(output == "beforeafter")
        }
    }

    @Test func aGenuineNetworkFailureIsRecoverableAndCatchableByProtect() async throws {
        try await withMockedIncludeURL(handler: { _, _ in throw URLError(.cannotConnectToHost) }) {
            var context = LassoContext()
            let output = try await LassoRenderer().render(
                "before-[protect]during-[include_url('http://mock.example/unreachable')]-unreached[/protect]-after-[error_currenterror]",
                context: &context
            )
            #expect(output == "before--after-Include_URL request failed.")
        }
    }
}

@Test func chainedStringReplaceCallsBuildASlugWithNoStrayOutput() async throws {
    // The exact real-corpus shape from pages/thumbs2.page.lasso (also
    // pages/thumbs.page.lasso, thumbs3.page.lasso, and every
    // templates/*/master.template.lasso's `$meta_keywords` line): several
    // bare `$var->(Replace(...))` statements in a row, progressively
    // cleaning a slug for later use in a URL. Before this fix, each of
    // the 5 calls echoed its (unchanged, since "Style (Test)" has none of
    // the *other* find characters at each step) intermediate value as
    // stray page text — reproduced live via
    // thekoiwarehouse.com/koi.lasso?page=subcats2, whose New Items grid
    // showed each product's style code repeated 5 times above its card.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        "[var(cleaned_product_name::string='Style (Test)')]" +
        "[$cleaned_product_name->(Replace('(',''))]" +
        "[$cleaned_product_name->(Replace(')',''))]" +
        "[$cleaned_product_name->(Replace('- ',''))]" +
        "[$cleaned_product_name->(Replace('\"',''))]" +
        "[$cleaned_product_name->(Replace(' ','-'))]" +
        "slug=[$cleaned_product_name]",
        context: &context
    )
    #expect(output == "slug=Style-Test")
}

@Test func fullIfElseBlockEmbeddedInOneSquareBracketSpanDoesNotSwallowFollowingContent() async throws {
    // Real corpus (pages/subcats.page.lasso) wraps a full condition/body/
    // else/close sequence in ONE square-bracket span:
    // `[if($product_subset == 'all') var(temp_tbl='ca_web') else
    // var(temp_tbl='lc_web') /if]` — not the usual `[if(...)] ... [/if]`
    // shape with separate bracket tags. The generic path only kept
    // `expressions.first` (the opening `if(...)` call) and silently
    // dropped everything else in that same span — no body, no `else`, no
    // closing tag ever became a real node — so `BlockBuilder` paired this
    // phantom open with whatever `[/if]`/`[else]` happened to appear
    // *later* in the page, swallowing all real content in between
    // (confirmed live: this exact page's category list and product
    // thumbnails never rendered).
    var trueContext = LassoContext(globals: ["product_subset": .string("all")])
    let trueOutput = try await LassoRenderer().render(
        """
        before
        [if($product_subset == 'all')
            var(temp_tbl::string = 'ca_web')
        else
            var(temp_tbl::string = 'lc_web')
        /if]
        temp_tbl is [$temp_tbl]
        after
        """,
        context: &trueContext
    )
    #expect(trueOutput.contains("temp_tbl is ca_web"))
    #expect(trueOutput.contains("after"))

    var falseContext = LassoContext(globals: ["product_subset": .string("koi")])
    let falseOutput = try await LassoRenderer().render(
        """
        before
        [if($product_subset == 'all')
            var(temp_tbl::string = 'ca_web')
        else
            var(temp_tbl::string = 'lc_web')
        /if]
        temp_tbl is [$temp_tbl]
        after
        """,
        context: &falseContext
    )
    #expect(falseOutput.contains("temp_tbl is lc_web"))
    #expect(falseOutput.contains("after"))
}

@Test func bareComparisonOperatorFlagIsEquivalentToOpEquals() async throws {
    // `-Cn` (and every other bare comparison-operator shorthand — `-Eq`,
    // `-Bw`, `-Ew`, `-Gt`, `-Gte`, `-Lt`, `-Lte`, `-Neq` — real Lasso/
    // FileMaker CWP syntax) is equivalent to `-Op='cn'` etc. Before this
    // was recognized, an unrecognized bare `-cn` fell into fieldArguments
    // and produced a bogus `LassoInlineCriterion(field: "cn", ...)`,
    // corrupting the generated SQL with a literal `cn` column reference
    // instead of applying `.contains` to the criterion that actually
    // followed it. Found live via pages/subcats.page.lasso's
    // `-cn, 'parent_id'=$bottom_cat, 'store_id'=$product_subset` — a
    // subcategory listing query that silently returned zero real category
    // rows (masked as "no matching data" until logging the underlying
    // MySQL error revealed "Unknown column 'cn' in 'where clause'").
    final class QueryRecorder: @unchecked Sendable {
        private(set) var queries: [DynamicQuery] = []
        func record(_ query: DynamicQuery) { queries.append(query) }
    }
    let recorder = QueryRecorder()
    let executor = PerfectCRUDLassoExecutor(
        capabilities: { _ in .readOnly },
        queryHandler: { _, query in
            recorder.record(query)
            return DynamicResult(rows: [], statement: "SELECT ...")
        }
    )
    let provider = LassoDynamicInlineProvider(executor: executor, datasourceAliases: ["catalog_mysql": "catalog"])
    var context = LassoContext(inlineProvider: provider)

    _ = try await LassoRenderer().render(
        "[inline(-database='catalog_mysql',-table='skus',-cn,'store_id'='abc',-search)][/inline]",
        context: &context
    )

    let seenQueries = recorder.queries
    #expect(seenQueries.count == 1)
    #expect(seenQueries[0].predicates == [
        DynamicPredicate(field: "store_id", comparison: .contains, value: .string("abc")),
    ])
}

@Test func opCarriesForwardToEveryFollowingFieldUntilOverridden() async throws {
    // A real `-Op` (or bare alias) applies to every field argument that
    // follows it, not just the one immediately after — it stays in effect
    // until the next `-Op`/alias overrides it. Found live via
    // pages/thumbs.page.lasso: `-op='cn', 'product_name'=$keyword,
    // 'special'=$show_specials, 'closeout'=$show_closeouts` has no `-op`
    // between `product_name` and `special`/`closeout`, so real Lasso
    // carries `cn` forward to all three. The previous implementation
    // zipped a flat operator list positionally against field arguments,
    // silently falling back to the default `Eq` for `special`/`closeout`
    // — turning a blank filter value's intended "no constraint" `LIKE
    // '%%'` into `= ''`, which matches nothing and silently zeroed out
    // every product search on a real corpus category page.
    final class QueryRecorder: @unchecked Sendable {
        private(set) var queries: [DynamicQuery] = []
        func record(_ query: DynamicQuery) { queries.append(query) }
    }
    let recorder = QueryRecorder()
    let executor = PerfectCRUDLassoExecutor(
        capabilities: { _ in .readOnly },
        queryHandler: { _, query in
            recorder.record(query)
            return DynamicResult(rows: [], statement: "SELECT ...")
        }
    )
    let provider = LassoDynamicInlineProvider(executor: executor, datasourceAliases: ["catalog_mysql": "catalog"])
    var context = LassoContext(inlineProvider: provider)

    _ = try await LassoRenderer().render(
        """
        [inline(-database='catalog_mysql',-table='products',-op='cn',
          'product_name'='',
          'special'='',
          'closeout'='',
        -search)][/inline]
        """,
        context: &context
    )

    let seenQueries = recorder.queries
    #expect(seenQueries.count == 1)
    #expect(seenQueries[0].predicates == [
        DynamicPredicate(field: "product_name", comparison: .contains, value: .string("")),
        DynamicPredicate(field: "special", comparison: .contains, value: .string("")),
        DynamicPredicate(field: "closeout", comparison: .contains, value: .string("")),
    ])
}

@Test func operatorFlagIsRecognizedAsALonghandAliasForOp() async throws {
    // `-Operator` is real Lasso 8/FileMaker CWP's longhand alias for
    // `-Op` — real corpus: pages/category_map.page.lasso's
    // `-Operator='cn', 'store_id'=$search_store`. Since "operator" wasn't
    // recognized, it fell into fieldArguments as a literal
    // `LassoInlineCriterion(field: "operator", ...)`, corrupting the
    // generated SQL with a nonexistent `operator` column reference and
    // silently failing the whole query — blanking the entire Site Map
    // page behind that one failed inline.
    final class QueryRecorder: @unchecked Sendable {
        private(set) var queries: [DynamicQuery] = []
        func record(_ query: DynamicQuery) { queries.append(query) }
    }
    let recorder = QueryRecorder()
    let executor = PerfectCRUDLassoExecutor(
        capabilities: { _ in .readOnly },
        queryHandler: { _, query in
            recorder.record(query)
            return DynamicResult(rows: [], statement: "SELECT ...")
        }
    )
    let provider = LassoDynamicInlineProvider(executor: executor, datasourceAliases: ["catalog_mysql": "catalog"])
    var context = LassoContext(inlineProvider: provider)

    _ = try await LassoRenderer().render(
        "[inline(-database='catalog_mysql',-table='lc_web','parent_id'='0',-Operator='cn','store_id'='abc',-search)][/inline]",
        context: &context
    )

    let seenQueries = recorder.queries
    #expect(seenQueries.count == 1)
    #expect(seenQueries[0].predicates == [
        DynamicPredicate(field: "parent_id", comparison: .equal, value: .string("0")),
        DynamicPredicate(field: "store_id", comparison: .contains, value: .string("abc")),
    ])
}

@Test func varCallWithTypeAnnotationAsAssignmentTargetDeclaresAndAssigns() async throws {
    // `Var(name::type) = value` — declare-then-assign as two tokens joined
    // by `=`, distinct from the single-call `var(name::type = default)`
    // form already handled by `declare(_:local:)`. Real corpus:
    // pages/thumbs.page.lasso's `[Var(cleaned_product_name::string) =
    // string(Field('product_name'))]`, inside the product-thumbnail loop.
    // This loop body was never exercised before the `-op` carry-forward
    // fix (the products query always returned zero rows), so this was a
    // latent parser gap the fix newly exposed rather than a regression —
    // `assign()`'s target-expression switch had no case for a `.call`
    // target at all, so it always fell to the `default: throw
    // invalidAssignment`.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        "[Var(greeting::string) = 'hello']|[$greeting]",
        context: &context
    )
    #expect(output == "|hello")
}

@Test func variableIsARealSynonymForVarNotJustAnUnrecognizedIdentifier() async throws {
    // Lasso 8.5 Language Guide's own synonym table lists [Variable] and
    // [Var] as exact synonyms ("Var → [Variable] [Var]"). Real corpus:
    // includes/b2b/*/top_right.lasso's `[variable: 'Season'=
    // (field:'new_season_number')]` — was unknownFunction("variable")
    // since only "var"/"local" were recognized as the declare-callee
    // special case, not "variable".
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        "[variable: 'greeting'='hello']|[$greeting]",
        context: &context
    )
    #expect(output == "|hello")
}

@Test func emailSendThrowsEmailNotConfiguredWhenNoEmailProviderIsWired() async throws {
    // [Email_Send] (Lasso 8.5 Language Guide, "Process Tags") — dispatches
    // through `context.emailProvider`
    // (Documentation/lasso-perfect-smtp-integration-plan.md §4.0's new
    // dispatch-registration seam). No provider is configured on a plain
    // `LassoContext()`, so this must throw
    // `LassoRuntimeError.emailNotConfigured` rather than silently
    // no-op'ing to `.void` — a deliberate behavior change from the old
    // stub (superseding `emailSendIsARegisteredNoOpNotAnUnknownFunction`,
    // which asserted the no-op behavior this replaces), mirroring how
    // `[inline]` throws `.inlineNotConfigured` when `inlineProvider` is
    // unset. Real corpus: importscripts/*.lasso's error-notification
    // `email_send: -to=..., -from=..., -subject=..., -body=...;`.
    var context = LassoContext()
    await #expect(throws: LassoRuntimeError.emailNotConfigured) {
        try await LassoRenderer().render(
            "before-[email_send: -to='a@example.com', -from='b@example.com', -subject='s', -body='b']-after",
            context: &context
        )
    }
}

@Test func emailSendDispatchesToTheConfiguredEmailProviderAndReturnsItsResult() async throws {
    // Proves the §4.0 dispatch seam actually reaches a configured
    // `LassoEmailProvider` end to end -- arguments evaluated by
    // `email_send`'s bare colon-call form arrive at the provider intact,
    // and `email_send`'s own evaluated value is whatever the provider
    // returns. Uses a test-double conformer (not the real
    // `LassoPerfectSMTP` target, which doesn't exist yet -- that's the
    // next implementation step, §4.0 point 2) the same way
    // `InlineProvider` test doubles exercise `LassoInlineProvider`
    // elsewhere in this file.
    final class EmailProviderRecorder: @unchecked Sendable {
        private(set) var calls: [[EvaluatedArgument]] = []
        func record(_ arguments: [EvaluatedArgument]) { calls.append(arguments) }
    }
    struct EmailProvider: LassoEmailProvider {
        let recorder: EmailProviderRecorder
        func send(_ arguments: [EvaluatedArgument], context: LassoContext) async throws -> LassoValue {
            recorder.record(arguments)
            return .string("queued")
        }
    }
    let recorder = EmailProviderRecorder()
    var context = LassoContext(emailProvider: EmailProvider(recorder: recorder))

    let output = try await LassoRenderer().render(
        "[email_send: -to='a@example.com', -from='b@example.com', -subject='s', -body='b']",
        context: &context
    )

    #expect(output == "queued")
    #expect(recorder.calls.count == 1)
    let seen = recorder.calls[0]
    #expect(seen.firstValue(named: "to") == .string("a@example.com"))
    #expect(seen.firstValue(named: "from") == .string("b@example.com"))
    #expect(seen.firstValue(named: "subject") == .string("s"))
    #expect(seen.firstValue(named: "body") == .string("b"))
}

@Test func decimalConstructorAndAsStringWithPrecisionFormatFixedDecimalPlaces() async throws {
    // `decimal(...)` (a native type constructor, like the already-supported
    // `integer(...)`/`string(...)`) plus `->asString(-precision=N)` — real
    // corpus: pages/thumbs.page.lasso's
    // `decimal(field('starting_price'))->asString(-precision=2)`, inside
    // the product-thumbnail loop. Also exercises `->asString(-precision=N)`
    // on a plain numeric expression (no explicit `decimal(...)` wrapper),
    // matching lassoBackup/scrubs/LassoApps/ds/_init.lasso's
    // `(...)->asstring(-precision=3)`.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        "[(decimal(19.5))->asString(-precision=2)]|[(3)->asString(-precision=1)]",
        context: &context
    )
    #expect(output == "19.50|3.0")
}

@Test func decimalCeilRoundsUpToTheNextWholeNumber() async throws {
    // `decimal->ceil` — real corpus: pages/thumbs.page.lasso's pagination
    // math, `((Decimal(Found_Count)) / Decimal($max_thumbs_displayed))->ceil`
    // (page count = total items divided by page size, rounded up).
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        "[Integer((Decimal(7) / Decimal(3))->ceil)]",
        context: &context
    )
    #expect(output == "3")
}

@Test func arrayInsertBuildsAnArrayOfPairsMutatingTheInvocantInPlace() async throws {
    // Real corpus: includes/detail_a_sku.lasso's
    // `$skuArrayItem->insert(field('scrubs_sku') = $temp_array)` (a bare
    // `key = value` call argument constructs a `.pair`, since
    // `field('scrubs_sku')` can't be a valid assignment target — this is
    // real Lasso 9 Pair-literal syntax, not an assignment) and
    // `$skuArrayColor->insert(field('color'))` (plain value, no pair) —
    // both called as bare statements with no `=`, relying on `->insert`
    // mutating the invocant variable in place. Read back via
    // includes/detail_by_color.lasso's `#skuItem->second->get:1` (a
    // colon-call on a member-access result).
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        """
        [var(items::array = array)]
        [$items->insert('a' = array(1, 2, 3))]
        [$items->insert('b' = array(4, 5, 6))]
        size=[$items->size]|first_key=[$items->first->first]|second_value_elem2=[$items->first->second->get:2]
        [var(plain::array = array)]
        [$plain->insert('x')]
        [$plain->insert('y')]
        plain=[$plain->get:1],[$plain->get:2]
        """,
        context: &context
    )
    #expect(output.contains("size=2"))
    #expect(output.contains("first_key=a"))
    #expect(output.contains("second_value_elem2=2"))
    #expect(output.contains("plain=x,y"))
}

@Test func arrayConstructorBuildsPairsFromLabeledArguments() async throws {
    // Lasso 8.5 Language Guide p.389 "Creating Arrays", worked example:
    // "[Array: 'Name_One'='Value_One', 'Name_Two'='Value_Two']" — "Each
    // name/value pair becomes a single pair within the array returned by
    // the tag." Previously `array(...)` silently discarded the label and
    // built `.array([.string("Value_One"), .string("Value_Two")])`.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        """
        [var(pairs::array = array('Name_One' = 'Value_One', 'Name_Two' = 'Value_Two'))]
        size=[$pairs->size]|k1=[$pairs->first->first]|v1=[$pairs->first->second]|k2=[$pairs->get(2)->first]|v2=[$pairs->get(2)->second]
        """,
        context: &context
    )
    #expect(output.contains("size=2"))
    #expect(output.contains("k1=Name_One"))
    #expect(output.contains("v1=Value_One"))
    #expect(output.contains("k2=Name_Two"))
    #expect(output.contains("v2=Value_Two"))
}

@Test func arrayConstructorPairArraySupportsMixedDuplicateKeysAndNonStringValues() async throws {
    // Lasso 8.5 Language Guide p.396 "Pair Arrays" worked example:
    // "[Variable: 'Pair_Array' = (Array: 'Alpha'='One', 'Beta'='Two',
    // 'Alpha'=1, 'Beta'=2)]" — a pair array can hold duplicate keys and
    // non-string pair values in the same array.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        """
        [var(pair_array::array = array('Alpha' = 'One', 'Beta' = 'Two', 'Alpha' = 1, 'Beta' = 2))]
        size=[$pair_array->size]|k1=[$pair_array->get(1)->first]|v1=[$pair_array->get(1)->second]\
        |k3=[$pair_array->get(3)->first]|v3=[$pair_array->get(3)->second]
        """,
        context: &context
    )
    #expect(output.contains("size=4"))
    #expect(output.contains("k1=Alpha"))
    #expect(output.contains("v1=One"))
    #expect(output.contains("k3=Alpha"))
    #expect(output.contains("v3=1"))
}

@Test func mapConstructorAcceptsIntegerLiteralKeys() async throws {
    // Lasso 8.5 Language Guide p.400 "To create a map", worked example:
    // "[Map: 1='Sunday', 2='Monday', 3='Tuesday', ...]" — "a map with
    // integer literals as keys." Previously `1='Sunday'` fell through to
    // the generic `.assignment` evaluation path (only `.string`/
    // `.identifier`/`.variable` assignment targets produced a label),
    // which tried to write back to an unassignable `.integer` target and
    // threw `invalidAssignment` before the map was ever built.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        """
        [var(days::map = map(1 = 'Sunday', 2 = 'Monday', 7 = 'Saturday'))]
        one=[$days->'1']|two=[$days->'2']|seven=[$days->'7']
        """,
        context: &context
    )
    #expect(output.contains("one=Sunday"))
    #expect(output.contains("two=Monday"))
    #expect(output.contains("seven=Saturday"))
}

@Test func bareColonCallArgumentDoesNotAbsorbATrailingArrowMemberAccess() async throws {
    // Parser bug found while regression-testing the fix above: a bare
    // colon-call (no parens) followed immediately by `->member`, as in
    // `$var->get:1->first`, must parse as `($var->get:1)->first` — the
    // `->first` targets the *call's result*. Previously `parsePostfix`'s
    // recursive parse of the colon-call's own argument value greedily
    // consumed the trailing `->first` as part of that argument (`1->first`),
    // producing `.member(base: .integer(1), name: "first")`, which threw
    // `unsupportedExpression("Member first")` since integers have no
    // `first` member. Contrast with the parenthesized form
    // `$var->get(1)->first`, which already worked because the `)` gives
    // the argument parse an unambiguous stopping point.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        """
        [var(items::array = array)]
        [$items->insert('a' = array(1, 2, 3))]
        [$items->insert('b' = array(4, 5, 6))]
        bare_colon=[$items->get:1->first]|parens=[$items->get(1)->first]
        """,
        context: &context
    )
    #expect(output.contains("bare_colon=a"))
    #expect(output.contains("parens=a"))
}

@Test func mapInsertAddsAKeyedEntryMutatingTheInvocantInPlace() async throws {
    // Real corpus: includes/detail_by_size.lasso's
    // `var(skuArrayItem = map)` followed by
    // `$skuArrayItem->insert(field('scrubs_sku')=array(...))` — unlike
    // the array case above, a `key = value` argument on a *map* invocant
    // is a real map insertion (add/overwrite the entry keyed by the left
    // side), not a Pair literal.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        """
        [var(m::map = map)]
        [$m->insert('koi247' = 'red')]
        value=[$m->koi247]
        """,
        context: &context
    )
    #expect(output.contains("value=red"))
}

@Test func iterateBindsTheNamedVariableFromItsSecondArgumentAndYieldsPairsForMaps() async throws {
    // Real corpus: includes/detail_by_size.lasso's
    // `iterate($skuArrayItem, var(skuItem))` (where `$skuArrayItem` is a
    // `map`, built via repeated `->insert(key = value)`), whose body only
    // ever references `$skuItem`/`#skuItem->second`, never the previous
    // hardcoded `loop_value` binding — and map iteration must yield
    // Pair(key, value) elements, not bare values, for `->first`/`->second`
    // to mean anything.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        """
        [var(m::map = map)]
        [$m->insert('a' = 1)]
        [iterate($m, var(item))][$item->first]=[$item->second->asString(-precision=0)];[/iterate]
        """,
        context: &context
    )
    #expect(output.contains("a=1;"))
}

@Test func loopAbortStopsTheEnclosingLoopBlockWithoutLeakingPastIt() async throws {
    // Loop_Abort() is Lasso's break — real corpus need: "find the first
    // matching row, then stop" search-cutoff patterns. `Renderer.swift`
    // had no early-exit hook in any loop construct at all before this;
    // confirms both that iteration stops exactly at the abort point and
    // that the page keeps rendering normally past the loop block itself.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        "[loop(5)][if(loop_count == 3)][loop_abort][/if][loop_count]|[/loop]after",
        context: &context
    )
    #expect(output == "1|2|after")
}

@Test func loopContinueSkipsOnlyTheRestOfTheCurrentIterationsBody() async throws {
    // Loop_Continue() is Lasso's continue — skips the remainder of the
    // current iteration's body (the `|` never prints for an even
    // iteration) but keeps looping, unlike Loop_Abort.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        "[loop(4)][if(loop_count % 2 == 0)][loop_continue][/if][loop_count]|[/loop]",
        context: &context
    )
    #expect(output == "1|3|")
}

@Test func loopAbortWorksInsideWhileIterateAndWithBlocksToo() async throws {
    // Same break semantics as the `loop` tests above, exercised across
    // every other looping construct (`Renderer.swift`'s "while"/
    // "iterate"/"with" block cases each needed their own
    // `consumeLoopControlSignal()` check).
    // Loop_Abort() exits *immediately* — it stops the current iteration's
    // body right where it's called, not just the loop's next iteration,
    // so `[#n]|` never prints for the iteration that calls it (n==3).
    var whileContext = LassoContext()
    let whileOutput = try await LassoRenderer().render(
        "[local(n = 0)][while(#n < 10)][#n += 1][if(#n == 3)][loop_abort][/if][#n]|[/while]",
        context: &whileContext
    )
    #expect(whileOutput == "1|2|")

    var iterateContext = LassoContext()
    let iterateOutput = try await LassoRenderer().render(
        "[iterate(array(10,20,30,40), var(x))][if($x == 30)][loop_abort][/if][$x]|[/iterate]",
        context: &iterateContext
    )
    #expect(iterateOutput == "10|20|")

    // `with`'s body uses the non-arrow `if(...) ... /if` script-mode form
    // rather than `if(...) => { ... }` — bisecting a surprising failure
    // here originally surfaced a real, pre-existing, unrelated parser bug:
    // a single-line arrow-block `if(...) => { ... }` at top-level script
    // scope silently swallowed its own body and closing `}` (see
    // `ScriptBodyParser.parseBlockOpening`/`parseIfOpening`'s
    // `skipLineRemainder()` fix and the `arrowBlockIf*` regression tests
    // below — now fixed, both forms behave identically). The non-arrow
    // form here still exercises the exact same `consumeLoopControlSignal()`
    // code path in the "with" block case, so it remains an equally valid
    // check of this stage's actual change.
    var withContext = LassoContext()
    _ = try await LassoRenderer().render(
        """
        <?lasso
        with x in array(10, 20, 30, 40) do {
            if(#x == 30)
                loop_abort
            /if
        }
        ?>
        """,
        context: &withContext
    )
    #expect(withContext.value(for: "x", scope: .local) == .integer(30))
}

// The three tests below pin down a real, pre-existing parser bug found
// while writing the test above: `ScriptBodyParser.parseBlockOpening` and
// `parseIfOpening` both called `skipLineRemainder()` unconditionally right
// after `consumeArrowBlockStartIfPresent()`, regardless of whether that
// call had just consumed a brace body's opening `{`. For a *multi-line*
// arrow body (`if(...) => {\n ... \n}`) this was harmless — the character
// immediately after `{` is already a newline, so "skip to the next line"
// is a no-op. But for a *single-line* arrow body (`if(...) => { ... }`,
// everything between `{` and `}` on one line), `skipLineRemainder()`
// blindly discarded every character up to the next newline — silently
// deleting the block's real body AND its own closing `}`, since neither
// `skipLineRemainder` nor its caller has any brace-depth awareness. With
// the closing `}` gone, `BlockBuilder`'s pairing search for that `if`'s
// close never finds one and keeps consuming whatever sibling nodes follow
// (in top-level script scope) as if they belonged to the `if`'s own body —
// exactly the "identical construct works nested in a `define`d tag body
// but not at top-level script scope" asymmetry this was originally
// reported as, even though the real bug has nothing to do with `define`
// vs. top-level scope specifically: `withInDoIteratesOverBareZeroArgTagCallResult`
// (nested in a `define`) only happened to dodge it because its arrow body
// is written multi-line, not because nesting inside `define` changes how
// the arrow body is parsed. Fixed by only calling `skipLineRemainder()`
// when no brace body was actually opened.
@Test func arrowBlockIfAtTopLevelScriptScopeDoesNotSwallowItsOwnBodyOrClose() async throws {
    // The minimal repro: a single-line arrow-block `if` directly in
    // top-level `<?lasso ?>` script scope, nothing else inside it. Before
    // the fix, `return 'yes'` and the `if`'s own closing `}` were both
    // silently discarded by `skipLineRemainder()`, so `BlockBuilder` never
    // found a close for the `if` and instead swallowed the trailing text
    // node and `[$canary]` expression that follow `?>` into the `if`'s
    // body — `return` never fired and the whole document's real output
    // vanished (rendered as empty string).
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        """
        <?lasso
        if(true) => { return 'yes' }
        ?>
        [$canary]
        """,
        context: &context
    )
    #expect(output.trimmingCharacters(in: .whitespacesAndNewlines) == "yes")
}

@Test func arrowBlockIfInsideATopLevelWithLoopAbortsTheLoopJustLikeTheSlashClosedForm() async throws {
    // Same scenario as `loopAbortWorksInsideWhileIterateAndWithBlocksToo`'s
    // `with` check above, but using the arrow-block `if` form instead of
    // `if(...) ... /if` — these two forms must behave identically, and
    // before the fix they did not: `loop_abort` was silently deleted along
    // with the arrow `if`'s closing `}`, so the loop never aborted and `x`
    // ended up `40` (ran to completion) instead of `30`.
    var context = LassoContext()
    _ = try await LassoRenderer().render(
        """
        <?lasso
        with x in array(10, 20, 30, 40) do {
            if(#x == 30) => { loop_abort }
        }
        ?>
        """,
        context: &context
    )
    #expect(context.value(for: "x", scope: .local) == .integer(30))
}

@Test func singleLineArrowBlockIfDoesNotCorruptSiblingBlockPairingOrDuplicateOutput() async throws {
    // The most subtle symptom: a single-line arrow-block `if` as the
    // SECOND statement in a top-level `with` body (whether or not its
    // condition is ever true). Before the fix, the arrow `if`'s swallowed
    // closing `}` made `BlockBuilder`'s pairing search consume the `with`
    // block's own closing `}` as if it belonged to the `if` instead —
    // leaving the `with` block itself unclosed, which `BlockBuilder`
    // resolved by treating the *rest of the top-level document* (the
    // `?>` delimiter's trailing text and the `[$collected]` output) as
    // the `with` block's body, so it was re-rendered once per loop
    // iteration.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        """
        <?lasso
        $collected = ''
        with x in array(10, 20, 30) do {
            $collected = $collected + #x + '|'
            if(#x == 999) => { local(dummy = 1) }
        }
        ?>
        [$collected]
        """,
        context: &context
    ).trimmingCharacters(in: .whitespacesAndNewlines)
    #expect(output == "10|20|30|")
}

@Test func loopAbortInANestedLoopOnlyStopsTheInnermostLoop() async throws {
    // Break/continue semantics, not a labeled/page-wide abort: an inner
    // `loop`'s own block case consumes its own signal via
    // `consumeLoopControlSignal()` before the outer loop's `render(body)`
    // call ever returns, so the outer loop never sees it.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        """
        [loop(3)]outer[loop_count]:[loop(3)][if(loop_count == 2)][loop_abort][/if]inner[loop_count],[/loop]|[/loop]
        """,
        context: &context
    )
    #expect(output == "outer1:inner1,|outer2:inner1,|outer3:inner1,|")
}

@Test func loopKeyIsThePositionForArraysAndTheMapKeyForMaps() async throws {
    // `loop_key()` — LassoGuide 9.3's documented default `iterate`
    // accessor alongside `loop_value`, previously unavailable to code
    // that doesn't use the `iterate(map, var(x))` binding form. For a map
    // source, `loop_key` must line up with `loop_value`'s own key half
    // (both are built from the exact same materialized snapshot so
    // Dictionary iteration order can't desync them).
    var arrayContext = LassoContext()
    let arrayOutput = try await LassoRenderer().render(
        "[iterate(array('a','b','c'))][loop_key]=[loop_value];[/iterate]",
        context: &arrayContext
    )
    #expect(arrayOutput == "1=a;2=b;3=c;")

    var mapContext = LassoContext()
    let mapOutput = try await LassoRenderer().render(
        """
        [var(m::map = map)]
        [$m->insert('a' = 1)]
        [iterate($m, var(item))][loop_key]=[$item->second->asString(-precision=0)];[/iterate]
        """,
        context: &mapContext
    )
    #expect(mapOutput.contains("a=1;"))
}

@Test func loopAbortStopsARecordsBlockPartwayThroughTheFoundSet() async throws {
    // Same break semantics as the other constructs, for `records`/`rows`
    // (the loop construct driven by `inline`'s query results rather than
    // an array/count/condition).
    let executor = PerfectCRUDLassoExecutor(
        capabilities: { _ in .readOnly },
        queryHandler: { _, _ in
            DynamicResult(
                rows: [
                    DynamicRow(["size": .string("XS")]),
                    DynamicRow(["size": .string("SM")]),
                    DynamicRow(["size": .string("XL")]),
                ],
                statement: "SELECT ..."
            )
        }
    )
    let provider = LassoDynamicInlineProvider(executor: executor, datasourceAliases: ["catalog_mysql": "catalog"])
    var context = LassoContext(inlineProvider: provider)
    let output = try await LassoRenderer().render(
        """
        <?lasso
            var('sizes' = array)
            inline(-database='catalog_mysql', -table='skus', -search)
                records
                    if(field('size') == 'SM')
                        loop_abort
                    /if
                    $sizes->insert(field('size'))
                /records
            /inline
        ?>
        count=[$sizes->size]
        """,
        context: &context
    )
    #expect(output.contains("count=1"))
}

@Test func loopAbortWithNoEnclosingLoopIsATrueNoOpNotAPageTruncation() async throws {
    // Real bug caught by architect + code review of this stage's own
    // diff: `RendererEngine.render(_:)`'s two shared early-exit checks
    // (`Renderer.swift`) fire on `loopControlSignal` exactly like they do
    // on `returnSignal` — but unlike `returnSignal`, nothing consumed
    // `loopControlSignal` at the top of the render chain, so a stray
    // `Loop_Abort()`/`Loop_Continue()` with no enclosing loop silently
    // truncated the rest of the page instead of doing nothing, directly
    // contradicting this feature's own doc comment. Fixed by
    // `LassoRenderer.render` discarding any leftover signal via
    // `clearLoopControlSignal()` once the document finishes rendering.
    var context = LassoContext()
    let output = try await LassoRenderer().render("before[loop_abort]after", context: &context)
    #expect(output == "beforeafter")
}

@Test func loopAbortInsideACustomTagDoesNotEscapeTheCallToHijackTheCallersLoop() async throws {
    // Second half of the same bug: `invokeCustomTag`/`invokeMemberMethod`
    // (Evaluator.swift) already firewall `returnSignal` at the tag-call
    // boundary (`clearReturnSignal()` before, `consumeReturnSignal()`
    // after) so a `return` inside a called tag can't leak past the call
    // site — but had no equivalent firewall for `loopControlSignal`. A
    // tag with no loop of its own that calls `Loop_Abort()` would leak
    // that signal back into the *caller's* context, silently aborting
    // whatever outer loop happened to be calling the tag after only one
    // iteration — the exact "loop nested inside another loop" containment
    // this whole feature is supposed to guarantee, defeated by a tag-call
    // indirection. Fixed by clearing `loopControlSignal` both before and
    // after `renderNodes(...)` in both functions, mirroring the existing
    // `returnSignal` firewall exactly.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        """
        <?lasso
        define noisyTag() => { loop_abort }
        ?>
        [loop(3)]x[loop_count][noisyTag()]|[/loop]
        """,
        context: &context
    ).trimmingCharacters(in: .whitespacesAndNewlines)
    #expect(output == "x1|x2|x3|")
}

@Test func loopAbortInsideAnIncludeCanAbortTheIncludingPagesEnclosingLoopJustLikeReturnCan() async throws {
    // The mirror image of the previous test: an `include` does NOT get
    // the same firewall as a custom tag call — `performInclude` never
    // touches `returnSignal` either, by design (see `LassoRenderer.render`'s
    // own doc comment: "A return at page/include level... contributes its
    // value to the page's output"), because an include shares the calling
    // page's scope instead of creating a new one, the same way a plain
    // pasted-in file would. `Loop_Abort`/`Loop_Continue` follow that same
    // precedent deliberately — `performInclude`/`performLibrary` were left
    // untouched by this fix on purpose, not by oversight.
    final class InMemoryIncludeLoader: LassoIncludeLoader, @unchecked Sendable {
        func loadInclude(path: String, from includingPath: String?) throws -> String {
            "[if(loop_count == 2)][loop_abort][/if]"
        }
    }
    var context = LassoContext(includeLoader: InMemoryIncludeLoader())
    let output = try await LassoRenderer().render(
        "[loop(5)]x[loop_count][include('abort_at_2.lasso')]|[/loop]after",
        context: &context
    )
    #expect(output == "x1|x2after")
}

@Test func renderErrorRecordsTheDeepestLocationAndIncludeStackNotTheOutermostOne() async throws {
    // Real corpus symptom this fixes: the dev server's error page always
    // showed "Include Stack: (empty)" no matter how deep the actual
    // include chain was — `LassoContext.includeStack` genuinely is empty
    // by the time a caller reads it after `LassoRenderer.render` throws,
    // because every `performInclude`/`performLibrary` frame's own
    // `defer` pops its entry as the error unwinds through it. The fix
    // records a frozen snapshot (`lastErrorLocation`/
    // `lastErrorIncludeStack`) at the moment the error first surfaces,
    // in `RendererEngine.render(_:)`, before any of that unwinding
    // happens — and it must be the *deepest* node/include, not an outer
    // one that only re-throws the same error on its way up.
    final class InMemoryIncludeLoader: LassoIncludeLoader, @unchecked Sendable {
        let content: String
        init(content: String) { self.content = content }
        func loadInclude(path: String, from includingPath: String?) throws -> String { content }
    }

    let loader = InMemoryIncludeLoader(content: "line1\nline2\n[totally_undefined_native()]\n")
    var context = LassoContext(includeLoader: loader)

    await #expect(throws: LassoRuntimeError.unknownFunction("totally_undefined_native")) {
        _ = try await LassoRenderer().render("before\n[include('bad.lasso')]", context: &context)
    }

    // The failing call sits on line 3 *of the included file*, not the
    // outer page (where the `[include(...)]` call itself is on line 2).
    #expect(context.lastErrorLocation?.start.line == 3)
    #expect(context.lastErrorIncludeStack == ["bad.lasso"])
}

@Test func renderErrorLocationIsNilForARecoverableErrorProtectSwallows() async throws {
    // A `[protect]`-caught `LassoRecoverableError` is handled, not a real
    // page failure — recording a location for it would misleadingly
    // suggest the page crashed when it didn't. This also guards the
    // `[protect]` mechanism itself: `RendererEngine.render(_:)` must
    // rethrow `LassoRecoverableError` completely unwrapped/unmodified, or
    // `[protect]`'s own `catch let recoverable as LassoRecoverableError`
    // stops matching and every recoverable error becomes fatal instead.
    // Same synthetic-tag setup as `protectCatchesRecoverableErrorAndSetsCurrentError`.
    var natives = LassoNativeRegistry()
    natives.register("fail_with_db_error") { _, _ in
        throw LassoRecoverableError(LassoErrorState(code: 42, message: "Add failed", kind: "add"))
    }
    var context = LassoContext(natives: natives)
    let output = try await LassoRenderer().render(
        "[protect]during-[fail_with_db_error]-unreached[/protect]-after",
        context: &context
    )
    // A protected body that fails partway discards everything rendered
    // up to the failure point (see `protect`'s own doc comment in
    // Renderer.swift) — "during-" never survives, only "-after" does.
    #expect(output == "-after")
    #expect(context.lastErrorLocation == nil)
}

@Test func renderErrorLocationIsPreciseToOneStatementInFullScriptModeFiles() async throws {
    // `ScriptBodyParser` (full `<?lasso ... ?>`-mode files, e.g. real
    // corpus includes/detail_a_sku.lasso) used to stamp every emitted
    // node with the exact same range — the range of the *entire*
    // script-mode span it was constructed with — so every error in such
    // a file reported the same near-meaningless "line 1, column 1"-ish
    // location regardless of which of potentially hundreds of statements
    // actually failed. Each statement now gets its own precise range.
    var context = LassoContext()
    await #expect(throws: LassoRuntimeError.unknownFunction("totally_undefined_native")) {
        _ = try await LassoRenderer().render(
            """
            <?lasso
                local(a = 1)
                local(b = 2)
                totally_undefined_native()
            ?>
            """,
            context: &context
        )
    }
    #expect(context.lastErrorLocation?.start.line == 4)
}

@Test func compoundAssignmentOperatorsDesugarToAssignTargetOpValue() async throws {
    // `+=`/`-=`/`*=`/`/=` weren't in the lexer's multi-character symbol
    // list at all, so `$html += '...'` lexed as separate `+` and `=`
    // tokens — a bare `=` with nothing before it isn't a valid
    // expression, throwing `unsupportedExpression("=")`. Real corpus:
    // ~300 occurrences of `$html +=`/`#out +=`-shaped HTML accumulator
    // statements across detail/cart pages (e.g.
    // includes/detail_a_sku.lasso), each one silently losing whatever
    // HTML the page had built up to that point.
    var context = LassoContext(globals: ["html": .string("a")])
    let output = try await LassoRenderer().render(
        "[$html += 'b'][$html]|[local(n = 10)][#n -= 3][#n]|[local(m = 4)][#m *= 2][#m]|[local(d = 10)][#d /= 4][#d]",
        context: &context
    )
    #expect(output == "ab|7|8|2.5")
}

@Test func stringLiteralInterpretsBackslashNTAndRAsRealControlCharacters() async throws {
    // Real Lasso string literals support the standard `\n`/`\t`/`\r`
    // control-character escapes — the lexer previously just dropped the
    // backslash and kept the literal next letter (`\n` -> "n", not an
    // actual newline). Real corpus: includes/detail_a_sku.lasso builds
    // page HTML via string literals like `'...\n|<br>|...'`, relying on
    // `\n` being an invisible real newline in the rendered HTML —
    // treating it as literal text inserted a visible, spurious "n"
    // everywhere one of these appeared, corrupting the whole product
    // detail page's dropdown/pricing markup.
    var context = LassoContext()
    let output = try await LassoRenderer().render("['a\\nb\\tc\\rd\\'e']", context: &context)
    #expect(output == "a\nb\tc\rd'e")
}

@Test func bareRecordsWithNoParensLoopsOnceForEachSearchResultInScriptMode() async throws {
    // `records` ... `/records` with no parens at all — real corpus:
    // includes/detail_a_sku.lasso's bare `records` on its own line
    // (script-mode, no `[...]` brackets). `parseBlockOpening` requires a
    // `(` immediately after the name, so this fell through to a
    // meaningless bare `.identifier` statement instead of a real block
    // opener — its "body" (everything up to `/records`) ran as flat,
    // un-looped top-level statements exactly once (using whatever row
    // Field() defaulted to with no active loop cursor), not once per
    // found row. On the real product detail page this silently built a
    // one-size dropdown instead of one `<option>` per real SKU.
    let executor = PerfectCRUDLassoExecutor(
        capabilities: { _ in .readOnly },
        queryHandler: { _, _ in
            DynamicResult(
                rows: [
                    DynamicRow(["size": .string("XS")]),
                    DynamicRow(["size": .string("SM")]),
                    DynamicRow(["size": .string("XL")]),
                ],
                statement: "SELECT ..."
            )
        }
    )
    let provider = LassoDynamicInlineProvider(executor: executor, datasourceAliases: ["catalog_mysql": "catalog"])
    var context = LassoContext(inlineProvider: provider)
    let output = try await LassoRenderer().render(
        """
        <?lasso
            var('sizes' = array)
            inline(-database='catalog_mysql', -table='skus', -search)
                records
                    $sizes->insert(field('size'))
                /records
            /inline
        ?>
        count=[$sizes->size]
        """,
        context: &context
    )
    #expect(output.contains("count=3"))
}

@Test func arrayInsertReturnsVoidNotTheMutatedContainerAsAStatementValue() async throws {
    // `->insert` mutates the invocant, but its *own* return value must be
    // void, not the mutated array/map — a bare script-mode or bracket
    // statement that calls `->insert` always echoes an expression's
    // return value, and no real corpus usage of `->insert` ever consumes
    // it. Returning the container here made a real product detail page
    // print a raw field dump (`KOI247-060-XS = Galaxy...`) directly onto
    // the page, right where `$skuArrayItem->insert(...)` runs as its own
    // statement (includes/detail_a_sku.lasso).
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        "before[var(items::array = array)][$items->insert('a')]after",
        context: &context
    )
    #expect(output == "beforeafter")
}

@Test func arraySortReverseJoinLastSecondAndContainsWork() async throws {
    // `array->sort`/`->reverse` mutate the invocant in place exactly like
    // `->insert` (LassoGuide Ch. 30) — confirmed here via the same bare-
    // statement write-back mechanism
    // `arrayInsertReturnsVoidNotTheMutatedContainerAsAStatementValue`
    // exercises for `->insert`. `->join`/`->last`/`->second`/`->contains`
    // are pure reads that never existed at all before this — sort/join/
    // remove were the single largest confirmed gap in the top-down
    // language review (Documentation/lasso85-gap-analysis-plan.md,
    // Section 4). `->find`/`->findPosition` are covered separately
    // (`arrayFindAndFindPositionReturnArraysOfAllMatchesNotABooleanOrFirstIndex`)
    // — an earlier version of this test conflated them with `->Contains`,
    // caught by architect review reading the Guide directly.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        """
        [var(nums::array = array(30, 10, 20))]
        [$nums->sort]sorted=[$nums->join(',')]|
        [$nums->reverse]reversed=[$nums->join(',')]|
        last=[$nums->last]|second=[$nums->second]|
        contains10=[$nums->contains(10)]|contains99=[$nums->contains(99)]
        """,
        context: &context
    )
    // Numeric-aware sort (not lexicographic, where "10" < "9"): 10, 20, 30.
    #expect(output.contains("sorted=10,20,30"))
    // ->reverse operates on the already-sorted array, not the original.
    #expect(output.contains("reversed=30,20,10"))
    #expect(output.contains("last=10"))
    #expect(output.contains("second=20"))
    #expect(output.contains("contains10=true"))
    #expect(output.contains("contains99=false"))
}

@Test func arraySortDescendingWhenGivenAFalseArgument() async throws {
    // Ch. 30 p.391/397: `[Array->Sort]` "Accepts a single boolean
    // parameter. Sorts in ascending order by default or if the parameter
    // is True and in descending order if the parameter is False." An
    // earlier version of this ignored the argument entirely.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        "[var(nums::array = array(3, 1, 2))][$nums->sort(false)]result=[$nums->join(',')]",
        context: &context
    )
    #expect(output.contains("result=3,2,1"))
}

@Test func arrayFindAndFindPositionReturnArraysOfAllMatchesNotABooleanOrFirstIndex() async throws {
    // Ch. 30 p.390/395-396, confirmed by reading the Guide's own worked
    // examples: `->Find` returns an ARRAY of every matching element
    // (`(6,1,4,1,5,1,2,3,1)->Find(1)` -> four 1s), `->FindPosition`
    // (previously `->FindIndex`) returns an array of the 1-based position
    // of every match, not just the first (`->FindPosition(1)` on the same
    // array -> `(2),(4),(6),(9)`). `->Contains` alone is the boolean form.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        """
        [var(nums::array = array(6, 1, 4, 1, 5, 1, 2, 3, 1))]
        found=[$nums->find(1)->join(',')]|
        positions=[$nums->findPosition(1)->join(',')]|
        missing=[$nums->find(99)->size]
        """,
        context: &context
    )
    #expect(output.contains("found=1,1,1,1"))
    #expect(output.contains("positions=2,4,6,9"))
    // A miss returns an empty array, not null/void/a crash.
    #expect(output.contains("missing=0"))
}

@Test func arrayFindOnAPairArrayComparesOnlyThePairsFirstHalf() async throws {
    // Ch. 30 p.396 ("Pair Arrays" -> "To find pairs within a pair array"):
    // "The parameter passed to the [Array->Find] tag is only compared to
    // the [Pair->First] element of each pair" — confirmed by the Guide's
    // own worked example (`Pair_Array->(Find: 'Alpha')` on an array of
    // `Alpha=One, Beta=Two, Alpha=1, Beta=2` pairs returns both Alpha
    // pairs). Real corpus relevance: `Action_Params`/`Params` both return
    // pair arrays. Built via explicit `pair(...)` calls, not
    // `array('Alpha'='One', ...)` name/value syntax — this interpreter's
    // `array(...)` constructor treats a `key = value` call argument as a
    // labeled argument (discarding the label) rather than a Pair literal
    // the way `Lasso 8.5 Language Guide` Ch. 30 p.389 documents; that's a
    // separate, real gap, flagged for follow-up rather than fixed here.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        """
        [var(pairs::array = array(pair('Alpha', 'One'), pair('Beta', 'Two'), pair('Alpha', 1), pair('Beta', 2)))]
        [iterate($pairs->find('Alpha'), var(p))][$p->first]=[$p->second];[/iterate]
        """,
        context: &context
    )
    #expect(output.contains("Alpha=One;Alpha=1;"))
}

@Test func arraySortOnAMixedNumericAndStringArrayIsAValidStrictWeakOrdering() async throws {
    // Regression for a real transitivity bug caught in self-review before
    // this ever reached a reviewer: a naive per-*pair* "both sides
    // numeric? compare numerically, else compare as strings" comparator
    // is inconsistent across a three-element mixed array (9 < 10
    // numerically, 10 < "5apple" as strings, but NOT 9 < "5apple" as
    // strings) — Swift's `sorted(by:)` doesn't validate strict weak
    // ordering, so this would have silently produced a wrong, order-
    // dependent result rather than crashing. The fix derives a single,
    // fixed per-element sort key up front instead of branching per pair.
    // This test only asserts the result is *a* valid total order (every
    // numeric element before every non-numeric one, each group correctly
    // internally ordered) — not a specific brittle character-by-character
    // output, since the exact non-numeric-group ordering is incidental.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        "[var(mixed::array = array(10, '5apple', 9))][$mixed->sort]result=[$mixed->join(',')]",
        context: &context
    )
    #expect(output.contains("result=9,10,5apple"))
}

@Test func arrayRemoveIsPositionBasedDefaultingToTheLastElement() async throws {
    // Ch. 30 p.390/393: "[Array->Remove] ... Accepts a single integer
    // parameter identifying the position of the item to be removed.
    // Defaults to the last item in the array." An earlier version of this
    // had `->remove` do VALUE-based removal (that's actually
    // `->RemoveAll`'s documented job — see the sibling test below) —
    // caught by architect review reading the Guide's own worked examples
    // (`$DaysOfWeek->(Remove)` removes the last item; `->(Remove: 4)`
    // removes position 4) directly, not by inference.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        """
        [var(days::array = array('Sunday', 'Monday', 'Tuesday', 'Wednesday'))]
        [$days->remove(4)]afterRemovePos4=[$days->join(',')]|
        [$days->remove]afterBareRemove=[$days->join(',')]
        """,
        context: &context
    )
    #expect(output.contains("afterRemovePos4=Sunday,Monday,Tuesday"))
    // Position 4 (Wednesday) is already gone; a bare `->remove` with no
    // argument now removes the new last item, Tuesday.
    #expect(output.contains("afterBareRemove=Sunday,Monday"))
}

@Test func arrayRemoveAllIsValueBasedDroppingEveryMatch() async throws {
    // Ch. 30 p.390/396: "[Array->RemoveAll] ... Removes any elements
    // that match the parameter from the array" — confirmed by the
    // Guide's own worked example: `$Delete_Array->(RemoveAll: 1)` on
    // `(6,1,4,1,5,1,2,3,1)` drops every `1`, leaving `(6,4,5,2,3)`.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        "[var(nums::array = array(6, 1, 4, 1, 5, 1, 2, 3, 1))][$nums->removeAll(1)]result=[$nums->join(',')]",
        context: &context
    )
    #expect(output.contains("result=6,4,5,2,3"))
}

@Test func arrayContainsFindAndRemoveAllMatchCaseInsensitivelyLikeTheRestOfTheInterpreter() async throws {
    // `->Contains`/`->Find`/`->RemoveAll` route element comparison through
    // the same case-insensitive `==` this interpreter already uses
    // everywhere else (see `doubleGreaterThanOperatorMeansStringContainsNotGreaterThan`'s
    // neighbor and `Evaluator.binary`'s own doc comment, which cites a
    // real production bug: thumbs2.page.lasso's ribbon check silently
    // breaking because `'Yes' != 'yes'` under case-sensitive comparison)
    // rather than Swift's raw case-sensitive `Equatable`. Caught by
    // architect review before this shipped.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        """
        [var(items::array = array('Yes', 'No', 'Yes'))]
        containsLower=[$items->contains('yes')]|
        foundCount=[$items->find('yes')->size]|
        [$items->removeAll('yes')]afterRemoveAll=[$items->join(',')]
        """,
        context: &context
    )
    #expect(output.contains("containsLower=true"))
    #expect(output.contains("foundCount=2"))
    #expect(output.contains("afterRemoveAll=No"))
}

@Test func mapSizeReturnsACountNotFallingThroughToTheBareKeyLookupCatchAll() async throws {
    // Real, silent bug caught by the top-down gap analysis (Documentation/
    // lasso9-lassoguide-gap-analysis-plan.md Section 2): before this
    // change, `.map`'s member dispatch had NO cases beyond `->insert` and
    // a bare-key-lookup catch-all (`values[normalized] ?? .null`) — so
    // `$myMap->size` on a map with no key literally named "size" silently
    // returned `.null` instead of the entry count, a genuine correctness
    // bug, not just a missing feature. `->size`/`->keys`/`->values`/
    // `->contains`/`->remove`/`->removeAll` now have explicit cases ahead
    // of that catch-all so they always mean the real method, never a key
    // lookup — matching real Lasso, where a map with an actual key named
    // "size" needs `->find('size')` to reach it instead.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        """
        [var(m::map = map)]
        [$m->insert('a' = 1)]
        [$m->insert('b' = 2)]
        size=[$m->size]|find_size=[$m->find('size')]
        """,
        context: &context
    )
    #expect(output.contains("size=2"))
    // No key literally named "size" was ever inserted -- confirms `->find`
    // still falls back to null for a genuine miss, distinct from `->size`.
    #expect(output.contains("find_size="))
    #expect(!output.contains("find_size=2"))
}

@Test func mapKeysValuesContainsFindRemoveAndRemoveAllWork() async throws {
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        """
        [var(m::map = map)]
        [$m->insert('a' = 1)]
        [$m->insert('b' = 2)]
        keys=[$m->keys->join(',')]|
        values=[$m->values->join(',')]|
        containsA=[$m->contains('a')]|containsZ=[$m->contains('z')]|
        findA=[$m->find('a')]|findZ=[$m->find('z')]|
        [$m->remove('a')]afterRemove=[$m->size]|
        [$m->removeAll]afterRemoveAll=[$m->size]
        """,
        context: &context
    )
    #expect(output.contains("keys=a,b"))
    #expect(output.contains("values=1,2"))
    #expect(output.contains("containsA=true"))
    #expect(output.contains("containsZ=false"))
    #expect(output.contains("findA=1"))
    // A miss returns void/empty, not a crash or a stray "z" key value.
    #expect(output.contains("findZ=|"))
    #expect(output.contains("afterRemove=1"))
    #expect(output.contains("afterRemoveAll=0"))
}

@Test func mapRemoveStaysAMethodEvenWhenTheMapHasALiteralRemoveKey() async throws {
    // Real bug caught by architect review: `->remove`/`->removeall` are
    // in `selfMutatingMethods`, so if they were key-first like `->size`/
    // `->keys`/etc., a map with a literal key named "remove" would hit
    // the key-first fallback (misreading a value) AND THEN
    // `evaluateStatement`'s self-mutating write-back would silently
    // overwrite the ENTIRE map variable with that key's raw value —
    // strictly worse than the original `->size` bug (a corrupting write,
    // not just a wrong read). Fixed by giving `.map`'s `->remove`/
    // `->removeall` the same unconditional priority `->insert` already
    // has, ahead of the key-first fallback, rather than key-first.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        """
        [var(m::map = map)]
        [$m->insert('remove' = 'a literal value, not a method call')]
        [$m->insert('other' = 'still here')]
        [$m->remove('other')]
        stillAMap=[$m->size]|removeValue=[$m->find('remove')]
        """,
        context: &context
    )
    // If ->remove had been mistakenly made key-first, $m would have been
    // overwritten with the string "a literal value, not a method call"
    // entirely, and ->size on a non-map would misbehave/crash.
    #expect(output.contains("stillAMap=1"))
    #expect(output.contains("removeValue=a literal value, not a method call"))
}

@Test func doubleGreaterThanOperatorMeansStringContainsNotGreaterThan() async throws {
    // Real Lasso 8/9's documented `>>` operator is string-contains
    // ("left contains right"), not a synonym for `>`. It was previously
    // implemented as one, which fell back to `compare`'s no-numeric-
    // operand path — comparing string *lengths*, not content — so it
    // only happened to look right for inputs where the length
    // comparison and the real contains-check agreed by coincidence.
    // Real corpus: ~32 files use `left >> 'substring'` for host/
    // environment detection and bot-string matching (e.g.
    // components/koi_setup.inc's `server_name >> 'www2'` chain).
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        "[('127.0.0.1' >> 'www2')]|[('www2.example.com' >> 'www2')]|[(12 > 3)]",
        context: &context
    )
    #expect(output == "false|true|true")
}

@Test func equalityOperatorComparesStringsCaseInsensitively() async throws {
    // Real Lasso 9 string `==` is case-insensitive by default (case-
    // sensitive comparison needs an explicit `-case` flag on
    // `string->compare`, not the bare operator). Found live:
    // pages/thumbs2.page.lasso's `if(string(field('new_item')) == 'yes')`
    // ribbon check — the real `skus` table stores this column as `'Yes'`
    // (capital Y, confirmed via a direct query against the real
    // datasource), yet production still shows the "New" ribbon on every
    // item in the New Items grid. A case-sensitive `==` made every
    // comparison fail, silently hiding the ribbon on the whole page.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        "[('Yes' == 'yes')]|[('Yes' != 'yes')]|[('Yes' == 'No')]",
        context: &context
    )
    #expect(output == "true|false|false")
}

@Test func elseWithConditionNestsAsRealIfElseIfNotAnUnconditionalBranch() async throws {
    // Real Lasso 8's if-else-if chaining (`if(A) ... else(B) ... else(C)
    // ... else ... /if`) must become nested if/else, not a flat
    // alternate. `BlockBuilder` previously discarded `else(condition)`'s
    // own condition entirely and always rendered whatever followed the
    // *first* else, silently dropping any branch past the second one —
    // real corpus: components/koi_setup.inc's server_name-based
    // environment-detection chain always picked its second branch
    // (secure3.iscrubs.com) regardless of the real host.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        """
        <?lasso
        if('x' == 'nope')
          'branch1'
        else('x' == 'nope')
          'branch2'
        else('x' == 'x')
          'branch3-correct'
        else
          'branch4-final'
        /if
        ?>
        """,
        context: &context
    )
    #expect(output.trimmingCharacters(in: .whitespacesAndNewlines) == "branch3-correct")

    // Every condition false must fall all the way through to the real
    // final (bare) else, not silently render nothing.
    var contextAllFalse = LassoContext()
    let outputAllFalse = try await LassoRenderer().render(
        """
        <?lasso
        if('x' == 'nope')
          'branch1'
        else('x' == 'nope')
          'branch2'
        else
          'branch3-final'
        /if
        ?>
        """,
        context: &contextAllFalse
    )
    #expect(outputAllFalse.trimmingCharacters(in: .whitespacesAndNewlines) == "branch3-final")
}

@Test func serverNameIsExposedAsABareGlobalTagNotJustAWebRequestMember() async throws {
    // Real Lasso 8's bare `server_name` global tag was completely
    // unregistered — it fell through to an ordinary (always
    // undeclared/empty) variable lookup, silently comparing against ""
    // in every real corpus usage (e.g. components/koi_setup.inc's
    // environment-detection chain). `web_request->serverName` already
    // exposed the same underlying value under a different calling
    // convention the corpus doesn't use.
    struct RequestProvider: LassoRequestProvider {
        let parameters: [String: LassoValue] = [:]
        func parameter(named name: String) -> LassoValue { .void }
        func header(named name: String) -> LassoValue { .void }
        func cookie(named name: String) -> LassoValue { .void }
        var serverName: String { "127.0.0.1" }
    }
    var context = LassoContext(requestProvider: RequestProvider())
    let output = try await LassoRenderer().render("[server_name]", context: &context)
    #expect(output == "127.0.0.1")
}

@Test func multipleOrdinaryStatementsInOneSquareBracketSpanAllExecute() async throws {
    // Real corpus: tims_loader.lasso's `[include('/a.inc')
    // include('/b.inc') include('/c.inc')]` — three sequential calls in
    // one square-bracket span, none of them a block-tag opener (unlike
    // the already-handled `if(...) ... else ... /if`-in-one-span case),
    // so the parser's fallback path only kept `expressions.first` and
    // silently dropped the rest. This made a real "reload my custom
    // tags" workflow only ever re-run the *first* included file's
    // defines, no matter how many files the loader page listed.
    final class InMemoryIncludeLoader: LassoIncludeLoader, @unchecked Sendable {
        func loadInclude(path: String, from includingPath: String?) throws -> String {
            switch path {
            case "/a.inc": return "<?lasso define greetA() => { return('hello A') } ?>"
            case "/b.inc": return "<?lasso define greetB() => { return('hello B') } ?>"
            default: return ""
            }
        }
    }
    var context = LassoContext(includeLoader: InMemoryIncludeLoader())
    let output = try await LassoRenderer().render(
        "[\ninclude('/a.inc')\ninclude('/b.inc')\n][greetA] / [greetB]",
        context: &context
    )
    #expect(output.contains("hello A"))
    #expect(output.contains("hello B"))
}

@Test func wrappedMemberCallWithNestedCallConsumesBothClosingParens() async throws {
    // `->(Method(args))` — real corpus's dominant wrapped member-call
    // shape (e.g. pages/subcats3.page.lasso's
    // `$uniform_restrictions->(Replace('!','<br>'))`). The old
    // `finishWrappedMember()` path consumed only the *inner* call's
    // closing paren (which happened to produce the right argument list)
    // and left the wrap's own outer closing paren dangling as a bogus
    // trailing token — invisible only because something else discarded
    // extra top-level expressions in the same span. Also covers the
    // `->(name: args)` colon-call and bare `->(name)` wrapped shapes,
    // which share the same parsing branch.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        "before[('no!smoking!allowed')->(Replace('!','<br>'))]after",
        context: &context
    )
    #expect(output == "beforeno<br>smoking<br>allowedafter")
}

// Tag-form consolidation, Commit A: TagCatalog replaces five previously
// hand-synced `Set<String>` tables (ScriptBodyParser.blockNames/
// bareBlockNames, BlockBuilder.blockNames, LassoParser's blockTagNames/
// bareBlockTagNames) with one scoped table. This is a pure data refactor —
// no parsing/dispatch behavior changes — so the parity test below is the
// safety net: it asserts the catalog reproduces every one of those five
// sets' membership exactly, both positively (every name that WAS in a set
// still answers true for that scope) and negatively (every name that was
// NOT in a set, including names in no set at all, still answers false) —
// a positive-only check would miss an accidentally-over-broad passthrough
// entry.
@Test func tagCatalogReproducesTheFiveReplacedSetsExactlyPerScope() throws {
    struct Expectation {
        let name: String
        let scriptBodyBlock: Bool
        let scriptBodyBare: Bool
        let blockBuilderBlock: Bool
        let lassoParserBlock: Bool
        let lassoParserBare: Bool
    }

    let expectations: [Expectation] = [
        // Ordinary blocks: real everywhere, bare-open everywhere except "if".
        Expectation(name: "if", scriptBodyBlock: true, scriptBodyBare: false, blockBuilderBlock: true, lassoParserBlock: true, lassoParserBare: false),
        Expectation(name: "inline", scriptBodyBlock: true, scriptBodyBare: true, blockBuilderBlock: true, lassoParserBlock: true, lassoParserBare: true),
        Expectation(name: "records", scriptBodyBlock: true, scriptBodyBare: true, blockBuilderBlock: true, lassoParserBlock: true, lassoParserBare: true),
        Expectation(name: "rows", scriptBodyBlock: true, scriptBodyBare: true, blockBuilderBlock: true, lassoParserBlock: true, lassoParserBare: true),
        Expectation(name: "loop", scriptBodyBlock: true, scriptBodyBare: false, blockBuilderBlock: true, lassoParserBlock: true, lassoParserBare: true),
        // iterate/while/protect gained real scriptBody bare-open recognition
        // in Phase 4 of tag-form consolidation — see TagCatalog.swift's
        // Phase 4 note: this fixed a genuine block-pairing bug (the
        // paren-less colon/bare form was previously falling through to a
        // meaningless flat `.code(...)` expression instead of a real
        // `.tag(...)` opener BlockBuilder could pair with its closer).
        Expectation(name: "iterate", scriptBodyBlock: true, scriptBodyBare: true, blockBuilderBlock: true, lassoParserBlock: true, lassoParserBare: true),
        Expectation(name: "while", scriptBodyBlock: true, scriptBodyBare: true, blockBuilderBlock: true, lassoParserBlock: true, lassoParserBare: true),
        Expectation(name: "protect", scriptBodyBlock: true, scriptBodyBare: true, blockBuilderBlock: true, lassoParserBlock: true, lassoParserBare: true),
        Expectation(name: "output_none", scriptBodyBlock: true, scriptBodyBare: true, blockBuilderBlock: true, lassoParserBlock: true, lassoParserBare: true),
        Expectation(name: "html_comment", scriptBodyBlock: true, scriptBodyBare: true, blockBuilderBlock: true, lassoParserBlock: true, lassoParserBare: true),
        Expectation(name: "encode_set", scriptBodyBlock: true, scriptBodyBare: true, blockBuilderBlock: true, lassoParserBlock: true, lassoParserBare: true),

        // select: scriptBody + lassoParser only (BlockBuilder special-cases it earlier).
        Expectation(name: "select", scriptBodyBlock: true, scriptBodyBare: false, blockBuilderBlock: false, lassoParserBlock: true, lassoParserBare: true),

        // define_tag/define_type: legacy colon-call form — blockBuilder pairing
        // + scriptBody bare-open only; never in lassoParser.
        Expectation(name: "define_tag", scriptBodyBlock: false, scriptBodyBare: true, blockBuilderBlock: true, lassoParserBlock: false, lassoParserBare: false),
        Expectation(name: "define_type", scriptBodyBlock: false, scriptBodyBare: true, blockBuilderBlock: true, lassoParserBlock: false, lassoParserBare: false),

        // define: own ScriptBodyParser opener (absent from scriptBody's
        // generic block set here), blockBuilder pairing + lassoParser
        // span-routing/bare-open.
        Expectation(name: "define", scriptBodyBlock: false, scriptBodyBare: false, blockBuilderBlock: true, lassoParserBlock: true, lassoParserBare: true),

        // with: own ScriptBodyParser opener, blockBuilder pairing only.
        Expectation(name: "with", scriptBodyBlock: false, scriptBodyBare: false, blockBuilderBlock: true, lassoParserBlock: false, lassoParserBare: false),

        // else/case: flat separators, own ScriptBodyParser function each,
        // never a blockBuilder-paired block; only lassoParser's broader
        // span-routing question includes them.
        Expectation(name: "else", scriptBodyBlock: false, scriptBodyBare: false, blockBuilderBlock: false, lassoParserBlock: true, lassoParserBare: true),
        Expectation(name: "case", scriptBodyBlock: false, scriptBodyBare: false, blockBuilderBlock: false, lassoParserBlock: true, lassoParserBare: true),

        // Controls: real Lasso identifiers that are NOT block-tag names at
        // all, in any of the five original sets — catches an
        // accidentally-over-broad passthrough entry.
        Expectation(name: "loop_value", scriptBodyBlock: false, scriptBodyBare: false, blockBuilderBlock: false, lassoParserBlock: false, lassoParserBare: false),
        Expectation(name: "field", scriptBodyBlock: false, scriptBodyBare: false, blockBuilderBlock: false, lassoParserBlock: false, lassoParserBare: false),
        Expectation(name: "not_a_real_tag_xyz", scriptBodyBlock: false, scriptBodyBare: false, blockBuilderBlock: false, lassoParserBlock: false, lassoParserBare: false),
    ]

    for expectation in expectations {
        #expect(TagCatalog.isBlock(expectation.name, in: .scriptBody) == expectation.scriptBodyBlock, "scriptBody block: \(expectation.name)")
        #expect(TagCatalog.allowsBareOpen(expectation.name, in: .scriptBody) == expectation.scriptBodyBare, "scriptBody bare: \(expectation.name)")
        #expect(TagCatalog.isBlock(expectation.name, in: .blockBuilder) == expectation.blockBuilderBlock, "blockBuilder block: \(expectation.name)")
        #expect(TagCatalog.isBlock(expectation.name, in: .lassoParser) == expectation.lassoParserBlock, "lassoParser block: \(expectation.name)")
        #expect(TagCatalog.allowsBareOpen(expectation.name, in: .lassoParser) == expectation.lassoParserBare, "lassoParser bare: \(expectation.name)")
    }

    // Case-insensitivity: the catalog lowercases internally, matching
    // every one of the five original call sites' `.lowercased()` calls.
    #expect(TagCatalog.isBlock("IF", in: .scriptBody))
    #expect(TagCatalog.isBlock("Records", in: .blockBuilder))
}

// A code-review finding on Commit B: `ScriptBodyParser.parseBlockOpening`'s
// fork into `parseIfOpening` is gated on `entry.openForms.contains(.bareCondition)`,
// which today only "if" satisfies — but nothing in the parity test above
// asserted that, so a future edit accidentally adding `.bareCondition` to
// some other entry would silently misroute that tag into "if"-specific
// parsing with no test catching it. This locks the invariant the fork
// depends on directly, rather than only indirectly via "if"'s own bare-
// condition rendering test.
@Test func onlyIfCarriesTheBareConditionFormRecordsAndRowsCarryBareIdentifier() throws {
    for (name, entry) in TagCatalog.shared {
        if name == "if" {
            #expect(entry.openForms.contains(.bareCondition), "if should support .bareCondition")
        } else {
            #expect(!entry.openForms.contains(.bareCondition), "\(name) should not support .bareCondition — only if does")
        }
    }
    #expect(TagCatalog.entry("records")?.openForms.contains(.bareIdentifier) == true)
    #expect(TagCatalog.entry("rows")?.openForms.contains(.bareIdentifier) == true)
}

// Phase 2 of tag-form consolidation: every catalog entry's `openForms` is
// now real, corpus-verified documentation (or a deliberate `[]` with an
// architectural reason) rather than an unexamined guess. Pinning the exact
// expected value per name catches an accidental edit silently
// reintroducing an unattested form (e.g. `while`'s dishonest `.parenCall`
// claim, proposed then caught and corrected during this phase's review —
// the corpus has zero real Lasso `while(...)` usage, only JavaScript false
// positives) just as much as it would catch a value going missing.
// Updated for Phase 4: `iterate`/`while`/`protect` gained real
// `bareOpenScopes` recognition (a genuine block-pairing bug fix, not just
// documentation — see TagCatalog.swift's Phase 4 note), and
// `.bareColonCall` now characterizes the colon-plus-arguments-no-parens
// shape `iterate`/`while`/`inline`/`encode_set`/`define_tag`/`define_type`
// all share (`protect`'s bare zero-arg form reuses `.bareIdentifier`
// instead, the same shape `records`/`rows` already had). `if` also gained
// `.bareColonCall` — real corpus's classic slash-closed `if: cond; ...
// /if;` (importscripts/*.lasso and 6 other pages), a genuine block-
// pairing bug fix distinct from `.bareCondition` (which requires a
// brace body, not a `;`-terminated one) — see `parseIfOpening`'s own
// classifier, not the shared cascade, since "if" stays deliberately
// isolated from it.
@Test func openFormsAreCharacterizedForEveryCatalogEntry() throws {
    let expected: [String: [TagOpenForm]] = [
        "if": [.parenCall, .colonCall, .bareCondition, .bareColonCall],
        "inline": [.parenCall, .bareColonCall],
        "records": [.parenCall, .colonCall, .bareIdentifier],
        "rows": [.parenCall, .colonCall, .bareIdentifier],
        "loop": [.parenCall, .colonCall],
        "iterate": [.parenCall, .bareColonCall],
        "while": [.bareColonCall],
        "protect": [.bareIdentifier],
        "output_none": [],
        "html_comment": [],
        "encode_set": [.parenCall, .bareColonCall],
        "select": [],
        "define_tag": [.bareColonCall],
        "define_type": [.bareColonCall],
        "define": [],
        "with": [],
        "else": [],
        "case": [],
    ]

    #expect(TagCatalog.shared.count == expected.count, "catalog entry count drifted from this test's expected map")
    for (name, forms) in expected {
        #expect(TagCatalog.entry(name)?.openForms == forms, "\(name) openForms mismatch")
    }
}

