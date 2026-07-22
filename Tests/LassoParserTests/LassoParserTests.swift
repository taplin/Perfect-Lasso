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

@Test func encryptMd5MatchesKnownVectors() async throws {
    // Independently-verifiable cryptographic test vectors (RFC 1321's
    // own test suite), not something requiring Lasso doc confirmation:
    // md5("") and md5("abc").
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        "[Encrypt_MD5('')]|[Encrypt_MD5('abc')]",
        context: &context
    )
    #expect(output == "d41d8cd98f00b204e9800998ecf8427e|900150983cd24fb0d6963f7d28e17f72")
}

@Test func encryptMd5AndCipherDigestOperateOnRawBytesNotALossyStringDecodeOfABytesObject() async throws {
    // Regression test (found by architect review): an earlier version
    // extracted the input via `.outputString`, which for a `.object`
    // bytes value routes through `LassoBytesValue.string(from:)` — an
    // explicitly-documented LOSSY UTF-8 decode — silently hashing
    // mangled data instead of the real bytes. `->decodeHex` builds
    // genuinely non-UTF-8-safe binary (bytes 0x00/0xFF aren't valid
    // standalone UTF-8), so hashing it must match hashing those exact
    // raw bytes directly, not a lossy re-decode of them.
    // Independently computed (Python hashlib, not this codebase) for
    // the raw two-byte sequence 0x00 0xFF.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        "[Encrypt_MD5(bytes('00ff')->decodeHex)]|[Cipher_Digest(bytes('00ff')->decodeHex, -digest='sha256', -hex)]",
        context: &context
    )
    #expect(output == "d07d34efac6328007ad67c7e0a985e00|06eb7d6a69ee19e5fbdf749018d3d2abfa04bcbd1365db312eb86dc7169389b8")
}

@Test func cipherDigestMatchesKnownVectorsForEachSupportedAlgorithm() async throws {
    // lassoguide.com "Calculate a Digest Value": `cipher_digest(field('message'), -digest='DSA')`
    // — DSA itself isn't implemented (see Hashing.swift's own scope
    // disclosure), but this exercises the same -Digest keyword shape
    // against algorithms this codebase does support, verified against
    // independently-known SHA1/SHA256 test vectors.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        "[Cipher_Digest('abc', -digest='sha1', -hex)]|[Cipher_Digest('abc', -digest='sha256', -hex)]",
        context: &context
    )
    #expect(output == "a9993e364706816aba3e25717850c26c9cd0d89d|ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
}

@Test func cipherDigestReturnsABytesObjectByDefaultWithoutHex() async throws {
    // "Returns... bytes" (lassoguide.com's own signature) — -Hex is an
    // explicit opt-in to a string encoding, not the default shape.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        "[Cipher_Digest('abc', -digest='md5')->type]",
        context: &context
    )
    #expect(output == "bytes")
}

@Test func cipherDigestWithAnUnsupportedAlgorithmFailsGracefullyRatherThanCrashing() async throws {
    // DSA/MD2/MD4/RIPEMD160 etc. are real, documented cipher_list(-digest)
    // entries this codebase doesn't implement (see Hashing.swift's own
    // disclosed scope) — must degrade to a recoverable error, not throw
    // an unrelated fatal error or silently return a wrong value.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        "[protect][Cipher_Digest('abc', -digest='dsa')][/protect][error_currenterror(-errorcode)]",
        context: &context
    )
    #expect(output == "\(LassoErrorHandling.Code.invalidParameter)")
}

@Test func cipherEncryptAndCipherDecryptRoundTripWithAesAndFailWithAWrongKey() async throws {
    // Real Lasso's own AES worked example uses `-cipher='DES-EDE3-CBC'`
    // (3DES, not AES) — this codebase's cipher_encrypt/decrypt only
    // implements AES via swift-crypto's AES-GCM (disclosed scope, see
    // Hashing.swift), so this exercises the actual supported algorithm
    // rather than the Guide's own specific worked example. Round-trip
    // correctness plus a wrong-key failure are both independently
    // verifiable properties, not something needing doc confirmation.
    var context = LassoContext()
    let roundTrip = try await LassoRenderer().render(
        "[var(enc = Cipher_Encrypt('a secret message', -cipher='AES', -key='correct horse'))]" +
        "[Cipher_Decrypt($enc, -cipher='AES', -key='correct horse')->asString]",
        context: &context
    )
    #expect(roundTrip == "a secret message")

    var wrongKeyContext = LassoContext()
    let wrongKeyOutput = try await LassoRenderer().render(
        "[var(enc = Cipher_Encrypt('a secret message', -cipher='AES', -key='correct horse'))]" +
        "[protect][Cipher_Decrypt($enc, -cipher='AES', -key='wrong key')][/protect][error_currenterror(-errorcode)]",
        context: &wrongKeyContext
    )
    #expect(wrongKeyOutput == "\(LassoErrorHandling.Code.invalidParameter)")
}

@Test func cipherEncryptUsesAFreshRandomNonceEachCallRatherThanAFixedOrReusedOne() async throws {
    // A real cryptographic property worth locking in with a test, not
    // just trusting AES.GCM.seal's documented behavior: encrypting the
    // identical plaintext with the identical key twice must produce
    // DIFFERENT ciphertext each time. A fixed/reused nonce would be a
    // real vulnerability (AES-GCM catastrophically leaks the XOR of two
    // plaintexts encrypted under the same key+nonce), so this isn't a
    // cosmetic check.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        "[var(first = Cipher_Encrypt('same message', -cipher='AES', -key='same key'))]" +
        "[var(second = Cipher_Encrypt('same message', -cipher='AES', -key='same key'))]" +
        "[$first->encodeHex->asString == $second->encodeHex->asString]",
        context: &context
    )
    #expect(output == "false")
}

@Test func cipherEncryptAndDecryptRoundTripAnEmptyPlaintext() async throws {
    // Regression test (caught by architect review): AES-GCM ciphertext
    // length equals plaintext length exactly (no padding), so
    // encrypting an empty string produces exactly `nonce + 0 +
    // tag` bytes — an earlier version's bounds check in
    // `cipherDecrypt` (`data.count > nonceSize + tagSize`) incorrectly
    // rejected exactly this valid, minimum-length ciphertext.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        "[var(enc = Cipher_Encrypt('', -cipher='AES', -key='a key'))]" +
        "[Cipher_Decrypt($enc, -cipher='AES', -key='a key')->asString]",
        context: &context
    )
    #expect(output == "")
}

@Test func cipherListReturnsTheActuallySupportedAlgorithmsNotTheFullRealLassoList() async throws {
    // Deliberately does NOT claim real Lasso's full OpenSSL-backed list
    // (DES/3DES/RC4/RC2/CAST5/RC5/etc.) — only what Hashing.swift's
    // digest()/cipherEncrypt() functions actually support, so a script
    // checking `cipher_list->contains(...)` before calling a cipher
    // never gets a false positive.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        "[(Cipher_List)->join(',')]|[(Cipher_List(-digest))->join(',')]",
        context: &context
    )
    #expect(output == "MD5,SHA1,SHA256,SHA384,SHA512,AES|MD5,SHA1,SHA256,SHA384,SHA512")
}

@Test func jsonDeserializeInvertsJsonSerializeForEveryDocumentedVariableType() async throws {
    // Documentation/session-upload-support-plan.md's own "Variable
    // strategy" list — string/integer/decimal/boolean/array/map/null —
    // is exactly what json_serialize/LassoValue.from(json:) already
    // round-trip for session persistence; this exercises the same
    // round trip through the new free tag.
    // 'f'=0/'g'=1 alongside 'd'=true are the exact combination that
    // regresses the `LassoValue.from(json:)` fix below if it's ever
    // reintroduced: `NSNumber as? Bool` only succeeds for a value of
    // exactly 0 or 1 (per SE-0170), so those two specific integers —
    // not 42/3.14/-5 — are what a naive `Bool`-checked-first `switch`
    // would misclassify as booleans instead of integers.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        "[var(m = Map('a'=1, 'b'='two', 'c'=(Array(1,2,3)), 'd'=true, 'e'=null, 'f'=0, 'g'=1.5))]" +
        "[var(roundTripped = Json_Deserialize(Json_Serialize($m)))]" +
        "[$roundTripped->find('a')]/[$roundTripped->find('a')->type]|" +
        "[$roundTripped->find('b')]|[$roundTripped->find('c')->join(',')]|" +
        "[$roundTripped->find('d')]/[$roundTripped->find('d')->type]|" +
        "[$roundTripped->find('e')->isA('null')]|" +
        "[$roundTripped->find('f')]/[$roundTripped->find('f')->type]|" +
        "[$roundTripped->find('g')]/[$roundTripped->find('g')->type]",
        context: &context
    )
    #expect(output == "1/Integer|two|1,2,3|true/Boolean|true|0/Integer|1.500000/Decimal")
}

@Test func lassoValueFromJsonDirectlyDistinguishesBooleansFromZeroAndOneValuedNumbers() async throws {
    // A direct, isolated unit test on `LassoValue.from(json:)` itself
    // (not just indirectly via `Json_Deserialize`'s full round trip
    // through `JSONSerialization`) — a future refactor of this exact
    // function, or of the session-restore call site that also depends
    // on it, has a regression guard even if it stops going through
    // `JSONSerialization` at all.
    #expect(LassoValue.from(json: NSNumber(value: true)) == .boolean(true))
    #expect(LassoValue.from(json: NSNumber(value: false)) == .boolean(false))
    #expect(LassoValue.from(json: NSNumber(value: 0)) == .integer(0))
    #expect(LassoValue.from(json: NSNumber(value: 1)) == .integer(1))
    #expect(LassoValue.from(json: NSNumber(value: 42)) == .integer(42))
    #expect(LassoValue.from(json: NSNumber(value: 3.14)) == .decimal(3.14))
    #expect(LassoValue.from(json: NSNull()) == .null)
}

@Test func jsonDeserializeOfMalformedJsonReturnsNullRatherThanThrowing() async throws {
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        "[Json_Deserialize('not valid json{{{')->type]",
        context: &context
    )
    #expect(output == "Null")
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

@Test func dateFieldCannotBeMutatedViaRawAssignment() async throws {
    // Phase C milestone review BLOCKING FIX #1: `Evaluator.assign`'s
    // `.member` case used to call `object.set(_:for:)` unconditionally for
    // ANY `.object` field assignment, with no check against
    // `context.nativeTypes` at all -- silently overwriting a native type's
    // internal storage and bypassing every invariant its real methods
    // enforce. `date`'s own stored fields ("year"/"month"/etc., see
    // `LassoDateParsing.makeObject`) happen to share names with its
    // registered read accessors, making the bug directly observable:
    // before the fix, `[$d->year = 5]` silently changed what `[$d->year]`
    // reported right back (since both read from the same raw field). Now
    // it must throw the dedicated error instead of silently no-opping.
    var context = LassoContext()
    await #expect(throws: LassoRuntimeError.nativeTypeFieldAssignmentNotSupported(typeName: "date", field: "year")) {
        _ = try await LassoRenderer().render(
            "[var(d = Date('2002-05-22'))][$d->year = 5]",
            context: &context
        )
    }
}

@Test func bytesFieldCannotBeMutatedViaRawAssignment() async throws {
    // Same bug class as the `date` case above, exercised against `bytes`'
    // private-by-convention `_base64` storage field (`BytesType.swift`).
    var context = LassoContext()
    await #expect(throws: LassoRuntimeError.nativeTypeFieldAssignmentNotSupported(typeName: "bytes", field: "_base64")) {
        _ = try await LassoRenderer().render(
            "[var(b = bytes('hello'))][$b->_base64 = 'AAAA']",
            context: &context
        )
    }
}

@Test func userDefinedTypeSelfMemberAssignmentStillWorksAfterTheNativeTypeFix() async throws {
    // Confirms BLOCKING FIX #1 did NOT break the real, load-bearing
    // `self->propname = value` instance-property-mutation mechanism for
    // USER-DEFINED Lasso types (resolved via `context.tagRegistry`, not
    // `context.nativeTypes`) -- already covered by
    // `typeDefinitionsConstructObjectsAndDispatchMethods` and the two
    // legacy `define_type` tests just below it, but this test names that
    // guarantee explicitly and directly, rather than leaving it merely
    // implied by pre-existing coverage.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        """
        <?lassoscript
        define Counter => type {
            data public count::integer
            public onCreate() => { self->count = 0 }
            public bump() => { self->count = self->count + 1 }
        }
        local(c::Counter = Counter())
        ?>
        [#c->bump][#c->bump][#c->bump][#c->count]
        """,
        context: &context
    ).trimmingCharacters(in: .whitespacesAndNewlines)
    #expect(output == "3")
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
    #expect(parts[1] == "101.000000")
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
    #expect(parts[1] == "0.125000")
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
    #expect(parts[0] == "3.141600")
    #expect(parts[1] == "3.142000")
    #expect(parts[2] == "3.140000")
    #expect(parts[3] == "3.100000")
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
    #expect(output == "27|10.000000")
}

@Test func mathAbsPreservesTheInvocantsIntegerOrDecimalType() async throws {
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        "[Math_Abs(-5)]|[Math_Abs(-5.5)]",
        context: &context
    )
    #expect(output == "5|5.500000")
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
    #expect(output == "-2|-5|-5.500000|5")
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

@Test func bytesSizeMatchesLassoguideComsOwnWorkedExample() async throws {
    // http://www.lassoguide.com/operations/byte-streams.html "Return the
    // Size of a Byte Stream": `bytes('abc…')->size // => 6` — the
    // ellipsis character is 3 UTF-8 bytes, so 'abc' (3) + '…' (3) = 6.
    var context = LassoContext()
    let output = try await LassoRenderer().render("[bytes('abc\u{2026}')->size]", context: &context)
    #expect(output == "6")
}

@Test func bytesGetReturnsAnIntegerByteValueMatchingLassoguideComsOwnWorkedExample() async throws {
    // "Return a Single Byte from a Byte Stream": `bytes('hello
    // world')->get(2) // => 101` (the ASCII code for the 1-based 2nd
    // character, 'e').
    var context = LassoContext()
    let output = try await LassoRenderer().render("[bytes('hello world')->get(2)]", context: &context)
    #expect(output == "101")
}

@Test func bytesGetRangeReturnsASliceAsANewBytesObject() async throws {
    var context = LassoContext()
    let output = try await LassoRenderer().render("[bytes('hello')->getRange(2, 3)->asString]", context: &context)
    #expect(output == "ell")
}

@Test func bytesFindMatchesLassoguideComsOwnWorkedExample() async throws {
    // "Find a Value Within a Byte Stream": `bytes('running rhinos risk
    // rampage')->find('rhino') // => 9`.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        "[bytes('running rhinos risk rampage')->find('rhino')]|[bytes('abc')->find('zzz')]",
        context: &context
    )
    #expect(output == "9|0")
}

@Test func bytesContainsBeginsWithAndEndsWithMatchTheirOwnWrittenDescriptionsNotTheBuggyWorkedExample() async throws {
    // lassoguide.com's "Determine If a Byte Stream Contains a Value"
    // section's own worked example actually calls `->find` (not
    // `->contains`) and expects a boolean `false` — which doesn't even
    // match `->find`'s own documented integer-or-zero return type. This
    // is a confirmed copy-paste artifact from the `->find` section
    // directly above it; implemented against `->contains`'s own written
    // description ("Returns 'true' if the byte stream contains the
    // specified sequence") instead, per NativeTypes.swift's own doc
    // comment on this registration.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        "[bytes('running rhinos risk rampage')->contains('rhino')]|[bytes('running rhinos risk rampage')->contains('zebra')]|[bytes('hello world')->beginsWith('hello')]|[bytes('hello world')->endsWith('world')]|[bytes('hello world')->beginsWith('world')]",
        context: &context
    )
    #expect(output == "true|false|true|true|false")
}

@Test func bytesAsStringDefaultsToUTF8MatchingLassoguideComsOwnWorkedExample() async throws {
    // "Export a String from a Byte Stream" uses `->exportString`
    // (deprecated-sibling form, not implemented this stage) with the
    // same "This is a string" worked value — `->asString` is its
    // documented UTF-8-default replacement.
    var context = LassoContext()
    let output = try await LassoRenderer().render("[bytes('This is a string')->asString]", context: &context)
    #expect(output == "This is a string")
}

@Test func bytesAsStringHonorsAnExplicitISO88591Encoding() async throws {
    // 0xE9 alone isn't valid UTF-8 (it's a 3-byte-sequence leading byte
    // with no continuation), but every byte value 0-255 is a valid
    // ISO-8859-1 character — 0xE9 is 'é'. Built via ->decodeHex since a
    // Lasso string literal can only produce UTF-8-encoded bytes, not an
    // arbitrary single non-ASCII byte directly.
    var context = LassoContext()
    let output = try await LassoRenderer().render("[bytes('e9')->decodeHex->asString('ISO-8859-1')]", context: &context)
    #expect(output == "\u{00E9}")
}

@Test func bytesSplitOnADelimiterAndOnAnEmptyDelimiterSplitsPerByte() async throws {
    // "If the delimiter provided is an empty byte stream or string, the
    // byte stream is split on each byte, so the returned array will have
    // each byte as one of its elements."
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        """
        [(bytes('a,b,c')->split(','))->size]
        [(bytes('a,b,c')->split(','))->get(1)->asString]|[(bytes('a,b,c')->split(','))->get(2)->asString]|[(bytes('a,b,c')->split(','))->get(3)->asString]
        [(bytes('ab')->split(''))->size]
        """,
        context: &context
    )
    let lines = output
        .split(separator: "\n")
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
    #expect(lines == ["3", "a|b|c", "2"])
}

@Test func bytesSubReturnsEverythingFromThePositionWhenNumIsOmitted() async throws {
    // Unlike `->getRange`, `->sub`'s second parameter is optional — "all
    // of the bytes following the index are returned" when omitted.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        "[bytes('hello world')->sub(7)->asString]|[bytes('hello world')->sub(1, 5)->asString]",
        context: &context
    )
    #expect(output == "world|hello")
}

@Test func bytesAppendTrimReplaceAndRemoveMutateTheInvocantInPlaceAsBareStatements() async throws {
    // Documented "Bytes Manipulation Methods" — "Calling the following
    // methods will modify the bytes object without returning a value" —
    // exactly the same self-mutating write-back mechanism
    // `String->Trim`/`->Append`/`->Replace`/`->Remove` already use
    // (`Evaluator.selfMutatingMethods` is purely syntactic/name-based,
    // not type-scoped, so no new entries were needed for `bytes`).
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        """
        [var(b::bytes=bytes('hello '))][$b->(append('world'))][$b->asString]|\
        [var(t::bytes=bytes('  hi  '))][$t->(trim)][$t->asString]|\
        [var(r::bytes=bytes('Blue Red Yellow'))][$r->(replace('Blue', 'Green'))][$r->asString]|\
        [var(rm::bytes=bytes('hello world'))][$rm->(remove(6, 6))][$rm->asString]|\
        [var(rmAll::bytes=bytes('abc'))][$rmAll->(remove)][$rmAll->asString]|end
        """,
        context: &context
    )
    #expect(output == "hello world|hi|Green Red Yellow|hello||end")
}

@Test func bytesEncodeHexAndDecodeHexRoundTrip() async throws {
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        "[bytes('AB')->encodeHex->asString]|[bytes('4142')->decodeHex->asString]",
        context: &context
    )
    #expect(output == "4142|AB")
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

@Test func inlineArrowBlockToleratesAutoCollectCaretMarkers() async throws {
    // Real corpus shape (TS_lasso9, near-universal across the site):
    // `inline(...)=>{^ ... ^}` -- `{^ ... ^}` is real, documented Lasso 9
    // syntax for an "auto-collect capture" (Ch. "Captures"), but for a
    // TagCatalog block tag like `inline` the body is always rendered as
    // template content via `Renderer.render(body)` -- there's no separate
    // capture object whose auto-collected value could ever be consumed,
    // so the `^` markers just need to be tolerated (consumed), not given
    // new semantics. Previously `consumeArrowBlockStartIfPresent` only
    // consumed the opening `{` (leaving a bare `^` to be parsed as the
    // start of the next statement, failing as unsupportedExpression("^")),
    // and `parseIgnoredBrace` only recognized a plain `}` (not `^}`).
    let scriptInline = """
    <?LassoScript
    inline(-database='catalog_mysql', -table='skus', -sql='SELECT 1;')=>{^
        action_statement;
    ^}
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

@Test func inlineArrowBlockAutoCollectMarkersWorkOnAnEmptyBody() async throws {
    // Real corpus shape (TS_lasso9's courts/main.lasso, index.lasso, and
    // others): `inline(...)=>{^\n^}` -- a genuinely empty auto-collect
    // body, nothing but whitespace between the two markers.
    let scriptInline = """
    <?LassoScript
    inline(-database='catalog_mysql', -table='skus', -sql='SELECT 1;')=>{^
    ^}
    'after'
    ?>
    """

    struct InlineProvider: LassoInlineProvider {
        func executeInline(arguments: [EvaluatedArgument], context: LassoContext) async throws -> LassoInlineFrame {
            LassoInlineFrame(rows: [])
        }
    }

    var context = LassoContext(inlineProvider: InlineProvider())
    let output = try await LassoRenderer().render(scriptInline, context: &context)
    #expect(output.trimmingCharacters(in: .whitespacesAndNewlines) == "after")
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

@Test func fileExistsIsDirectoryAndGetSizeReflectRealFilesystemState() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("lasso-file-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: root.appendingPathComponent("sub"), withIntermediateDirectories: true)
    try "hello".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: root) }

    var context = LassoContext(includeLoader: try LassoFileSystemIncludeLoader(root: root))
    let output = try await LassoRenderer().render(
        "[File_Exists: 'a.txt']|[File_Exists: 'missing.txt']|[File_IsDirectory: 'sub']|[File_IsDirectory: 'a.txt']|[File_GetSize: 'a.txt']",
        context: &context
    )
    #expect(output == "true|false|true|false|5")
}

@Test func fileCreationDateAndModDateReturnRealDateObjects() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("lasso-file-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try "hello".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: root) }

    var context = LassoContext(includeLoader: try LassoFileSystemIncludeLoader(root: root))
    let output = try await LassoRenderer().render(
        "[(File_CreationDate: 'a.txt')->year]|[(File_ModDate: 'a.txt')->year]",
        context: &context
    )
    let currentYear = Calendar(identifier: .gregorian).component(.year, from: Date())
    #expect(output == "\(currentYear)|\(currentYear)")
}

@Test func fileWriteThenReadRoundTripsAndOverwriteVsAppendBehaveAsDocumented() async throws {
    // Ch. 31 Table 1: "[File_Write]... Optional -FileOverWrite keyword
    // specifies that the destination file should be overwritten if it
    // exists, otherwise the data specified is appended to the end of the
    // file."
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("lasso-file-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    var context = LassoContext(includeLoader: try LassoFileSystemIncludeLoader(root: root))
    let output = try await LassoRenderer().render(
        """
        [File_Write: 'out.txt', 'Hello', -FileOverWrite][File_Read: 'out.txt']|\
        [File_Write: 'out.txt', ' World'][File_Read: 'out.txt']|\
        [File_Write: 'out.txt', 'Reset', -FileOverWrite][File_Read: 'out.txt']
        """,
        context: &context
    )
    #expect(output == "Hello|Hello World|Reset")
}

@Test func fileCreateMakesAFileOrADirectoryDependingOnATrailingSlash() async throws {
    // "If the file name ends in a / then a directory is created."
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("lasso-file-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    var context = LassoContext(includeLoader: try LassoFileSystemIncludeLoader(root: root))
    let output = try await LassoRenderer().render(
        "[File_Create: 'newfile.txt'][File_Exists: 'newfile.txt']|[File_Create: 'newdir/'][File_IsDirectory: 'newdir']",
        context: &context
    )
    #expect(output == "true|true")
}

@Test func fileCreateWithoutOverwriteOnAnExistingFileSetsFileAlreadyExistsError() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("lasso-file-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try "existing".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: root) }

    var context = LassoContext(includeLoader: try LassoFileSystemIncludeLoader(root: root))
    let output = try await LassoRenderer().render(
        "[File_Create: 'a.txt'][File_CurrentError: -ErrorCode]: [File_CurrentError]",
        context: &context
    )
    #expect(output == "-9983: File already exists.")
}

@Test func fileDeleteRemovesAFileAndFileCurrentErrorReportsNoErrorAfterASuccessfulOperation() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("lasso-file-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try "bye".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: root) }

    var context = LassoContext(includeLoader: try LassoFileSystemIncludeLoader(root: root))
    let output = try await LassoRenderer().render(
        "[File_Delete: 'a.txt'][File_Exists: 'a.txt']|[File_CurrentError: -ErrorCode]",
        context: &context
    )
    #expect(output == "false|0")
}

@Test func fileListDirectoryMarksSubdirectoriesWithATrailingSlashMatchingTheLanguageGuidesOwnWorkedExample() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("lasso-file-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: root.appendingPathComponent("Images"), withIntermediateDirectories: true)
    try "x".write(to: root.appendingPathComponent("default.htm"), atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: root) }

    var context = LassoContext(includeLoader: try LassoFileSystemIncludeLoader(root: root))
    let output = try await LassoRenderer().render(
        "[(File_ListDirectory: '/')->join(',')]",
        context: &context
    )
    #expect(output == "Images/,default.htm")
}

@Test func fileCopyAndFileMoveAndFileRenameOperateOnRealFiles() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("lasso-file-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try "content".write(to: root.appendingPathComponent("source.txt"), atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: root) }

    var context = LassoContext(includeLoader: try LassoFileSystemIncludeLoader(root: root))
    let output = try await LassoRenderer().render(
        """
        [File_Copy: 'source.txt', 'copy.txt'][File_Exists: 'source.txt']|[File_Exists: 'copy.txt']|\
        [File_Move: 'copy.txt', 'moved.txt'][File_Exists: 'copy.txt']|[File_Exists: 'moved.txt']|\
        [File_Rename: 'moved.txt', 'renamed.txt'][File_Exists: 'moved.txt']|[File_Exists: 'renamed.txt']
        """,
        context: &context
    )
    #expect(output == "true|true|false|true|false|true")
}

@Test func fileTagsConfinePathsToTheSameRootIncludeAlreadyUsesAndDegradeGracefullyRatherThanCrashing() async throws {
    // File_* tags reuse `LassoIncludeLoader.fileSystemRoot` — the SAME
    // confinement `include()`/`library()` already rely on — rather than
    // a second, independently-configured root. A path that escapes it
    // must degrade gracefully (false/void + a File_CurrentError), never
    // crash or silently touch the real filesystem outside the root.
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("lasso-file-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    var context = LassoContext(includeLoader: try LassoFileSystemIncludeLoader(root: root))
    let output = try await LassoRenderer().render(
        "[File_Exists: '../../../etc/passwd']",
        context: &context
    )
    #expect(output == "false")
}

@Test func fileWriteCannotEscapeConfinementThroughASymlinkedIntermediateDirectory() async throws {
    // Regression test: `resolvedURL`'s "target doesn't exist yet" branch
    // (the one `File_Create`/`File_Write` use) must still resolve real,
    // already-existing intermediate directory symlinks before its own
    // confinement check — an earlier version only did this in the
    // existing-file branch, so a symlink planted inside root pointing
    // OUTSIDE it (`root/evil -> outside/`) passed confinement on the
    // unresolved lexical path (`<root>/evil/newfile.txt` textually
    // starts with root's own path) while the actual write would have
    // gone through the symlink to the real, unconfined target — the OS
    // follows intermediate-directory symlinks regardless of whether the
    // final path component exists yet.
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("lasso-file-\(UUID().uuidString)")
    let outside = FileManager.default.temporaryDirectory
        .appendingPathComponent("lasso-file-outside-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("evil"), withDestinationURL: outside)
    defer {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: outside)
    }

    var context = LassoContext(includeLoader: try LassoFileSystemIncludeLoader(root: root))
    let output = try await LassoRenderer().render(
        "[File_Write: 'evil/newfile.txt', 'leaked']",
        context: &context
    )
    #expect(output == "")
    #expect(FileManager.default.fileExists(atPath: outside.appendingPathComponent("newfile.txt").path) == false)
}

@Test func fileRenameCannotEscapeConfinementThroughATraversingNewName() async throws {
    // Regression test: `File_Rename`'s second parameter is documented
    // (Ch. 31 Table 1) as a bare NAME, not a path — but an earlier
    // version trusted that documented contract from untrusted input,
    // building the destination with plain string concatenation
    // (`sourceURL.deletingLastPathComponent().appendingPathComponent(newName)`)
    // with NO confinement check at all. A `newName` containing `../`
    // traversal components reached a real, unconfined location on the
    // actual filesystem with no symlink or special setup required — the
    // single most directly exploitable finding from architect review.
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("lasso-file-\(UUID().uuidString)")
    let outside = FileManager.default.temporaryDirectory
        .appendingPathComponent("lasso-file-outside-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    try "secret".write(to: root.appendingPathComponent("source.txt"), atomically: true, encoding: .utf8)
    defer {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: outside)
    }

    var context = LassoContext(includeLoader: try LassoFileSystemIncludeLoader(root: root))
    _ = try await LassoRenderer().render(
        "[File_Rename: 'source.txt', '../\(outside.lastPathComponent)/leaked.txt']",
        context: &context
    )
    #expect(FileManager.default.fileExists(atPath: outside.appendingPathComponent("leaked.txt").path) == false)
    // The source is untouched since the rename was correctly rejected —
    // confirms this degraded gracefully rather than partially applying.
    #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("source.txt").path) == true)
}

@Test func fileDeleteRefusesToDeleteTheConfinedRootItself() async throws {
    // Regression test: an empty/"."/"/" path resolves to the confined
    // root itself via `resolvedURL`'s own logic (a directory always
    // exists, so it satisfies the existing-file loop trivially) —
    // `removeItem` on a directory recurses, so an earlier version would
    // have recursively deleted the entire confined site root for a
    // blank/unset `File_Delete` argument (e.g.
    // `File_Delete($_POST('filename'))` with no field submitted).
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("lasso-file-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try "still here".write(to: root.appendingPathComponent("sentinel.txt"), atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: root) }

    var context = LassoContext(includeLoader: try LassoFileSystemIncludeLoader(root: root))
    _ = try await LassoRenderer().render("[File_Delete: '']", context: &context)
    #expect(FileManager.default.fileExists(atPath: root.path) == true)
    #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("sentinel.txt").path) == true)
}

@Test func fileCopyAndFileMoveRefuseToOverwriteTheConfinedRootAsADestination() async throws {
    // Regression test (found by a second, adversarial review pass on
    // the fixes above — the same root-destination bug class as
    // `File_Delete`/`File_Rename`, just on two sibling tags): a blank/
    // "."/"/" `destination` resolves to the confined root itself, since
    // the root directory always exists. Without a guard, an ordinary
    // `-FileOverwrite` on that destination would hit the "destination
    // exists, overwrite requested" branch and recursively delete the
    // entire confined root via `removeItem` before the copy/move even
    // ran — reachable via nothing more unusual than a blank destination
    // field plus a flag many real callers set as a matter of course.
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("lasso-file-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try "still here".write(to: root.appendingPathComponent("sentinel.txt"), atomically: true, encoding: .utf8)
    try "payload".write(to: root.appendingPathComponent("source.txt"), atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: root) }

    var context = LassoContext(includeLoader: try LassoFileSystemIncludeLoader(root: root))
    _ = try await LassoRenderer().render(
        "[File_Copy: 'source.txt', '', -FileOverwrite][File_Move: 'source.txt', '/', -FileOverwrite]",
        context: &context
    )
    #expect(FileManager.default.fileExists(atPath: root.path) == true)
    #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("sentinel.txt").path) == true)
    #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("source.txt").path) == true)
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

// MARK: - LassoApps (library-loading slice — see loadLassoApps's own doc comment)

@Test func lassoAppsLoadsInitFilesAcrossMultipleAppsAndSkipsHiddenEntries() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("lasso-apps-\(UUID().uuidString)")
    let appA = root.appendingPathComponent("AppA")
    let appB = root.appendingPathComponent("AppB")
    let hidden = root.appendingPathComponent(".DS_Store")
    try FileManager.default.createDirectory(at: appA, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: appB, withIntermediateDirectories: true)
    try "junk".write(to: hidden, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: root) }

    try "<?lassoscript define greetFromA => { return('hi from A') } ?>".write(
        to: appA.appendingPathComponent("_init.lasso"), atomically: true, encoding: .utf8
    )
    try "<?lassoscript define greetFromB => { return('hi from B') } ?>".write(
        to: appB.appendingPathComponent("_init.lasso"), atomically: true, encoding: .utf8
    )

    let registry = LassoTagRegistry()
    let result = await loadLassoApps(at: root, tagRegistry: registry)

    #expect(Set(result.loadedFiles) == ["AppA/_init.lasso", "AppB/_init.lasso"])
    #expect(result.failedFiles.isEmpty)
    #expect(registry.containsTag(named: "greetFromA"))
    #expect(registry.containsTag(named: "greetFromB"))
}

@Test func lassoAppsOnlyLoadsInitPrefixedLassoFilesAtAnAppsOwnRoot() async throws {
    // Real Lasso: "named beginning with '_init.' ... Only initialization
    // files at the root of the LassoApp are executed" — an ordinary
    // sibling file (like ds's own `ds.lasso`) must NOT auto-run; it's
    // only ever reached via an _init file's own `lassoapp_include`.
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("lasso-apps-\(UUID().uuidString)")
    let app = root.appendingPathComponent("ds")
    let subdir = app.appendingPathComponent("nested")
    try FileManager.default.createDirectory(at: subdir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    try "<?lassoscript define fromInit => { return('init ran') } ?>".write(
        to: app.appendingPathComponent("_init.lasso"), atomically: true, encoding: .utf8
    )
    try "<?lassoscript define fromSibling => { return('should not auto-run') } ?>".write(
        to: app.appendingPathComponent("ds.lasso"), atomically: true, encoding: .utf8
    )
    try "<?lassoscript define fromNested => { return('should not auto-run either') } ?>".write(
        to: subdir.appendingPathComponent("_init.lasso"), atomically: true, encoding: .utf8
    )

    let registry = LassoTagRegistry()
    let result = await loadLassoApps(at: root, tagRegistry: registry)

    #expect(result.loadedFiles == ["ds/_init.lasso"])
    #expect(result.failedFiles.isEmpty)
    #expect(registry.containsTag(named: "fromInit"))
    #expect(registry.containsTag(named: "fromSibling") == false)
    #expect(registry.containsTag(named: "fromNested") == false)
}

@Test func lassoAppsContinuesPastAFailingAppInitFileAndReportsIt() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("lasso-apps-\(UUID().uuidString)")
    let goodApp = root.appendingPathComponent("Good")
    let brokenApp = root.appendingPathComponent("Broken")
    try FileManager.default.createDirectory(at: goodApp, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: brokenApp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    try "<?lassoscript define stillWorks => { return('ok') } ?>".write(
        to: goodApp.appendingPathComponent("_init.lasso"), atomically: true, encoding: .utf8
    )
    try "<?lassoscript totallyUndefinedFunctionCall() ?>".write(
        to: brokenApp.appendingPathComponent("_init.lasso"), atomically: true, encoding: .utf8
    )

    let registry = LassoTagRegistry()
    let result = await loadLassoApps(at: root, tagRegistry: registry)

    #expect(result.loadedFiles == ["Good/_init.lasso"])
    #expect(result.failedFiles.count == 1)
    #expect(result.failedFiles.first?.file == "Broken/_init.lasso")
    #expect(result.failedFiles.first?.error.contains("totallyUndefinedFunctionCall") == true)
    #expect(registry.containsTag(named: "stillWorks"))
}

@Test func lassoAppsHandlesMissingDirectoryGracefully() async {
    let missing = FileManager.default.temporaryDirectory
        .appendingPathComponent("lasso-apps-does-not-exist-\(UUID().uuidString)")
    let registry = LassoTagRegistry()

    let result = await loadLassoApps(at: missing, tagRegistry: registry)

    #expect(result.loadedFiles.isEmpty)
    #expect(result.failedFiles.count == 1)
    #expect(result.failedFiles.first?.error == "not a directory or does not exist")
}

@Test func lassoappIncludeResolvesRelativeToItsOwnAppsDirectoryNotAnotherAppsOrTheSiteRoot() async throws {
    // Real corpus shape (zeroloop/ds's own _init.lasso): a loop over
    // sibling filenames, each pulled in via lassoapp_include -- must
    // resolve against THIS app's own folder even though a
    // same-named file also exists in a sibling app's folder, to prove
    // it isn't accidentally falling through to some other root.
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("lasso-apps-\(UUID().uuidString)")
    let dsApp = root.appendingPathComponent("ds")
    let otherApp = root.appendingPathComponent("other")
    try FileManager.default.createDirectory(at: dsApp, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: otherApp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    try "<?lassoscript define whichDs => { return('real ds sibling') } ?>".write(
        to: dsApp.appendingPathComponent("sequential.lasso"), atomically: true, encoding: .utf8
    )
    try "<?lassoscript define whichOther => { return('wrong app entirely') } ?>".write(
        to: otherApp.appendingPathComponent("sequential.lasso"), atomically: true, encoding: .utf8
    )
    try """
    <?lassoscript
    with file in array('sequential.lasso') do {
        lassoapp_include(#file)
    }
    ?>
    """.write(to: dsApp.appendingPathComponent("_init.lasso"), atomically: true, encoding: .utf8)

    let registry = LassoTagRegistry()
    let result = await loadLassoApps(at: root, tagRegistry: registry)

    #expect(result.failedFiles.isEmpty)
    #expect(registry.containsTag(named: "whichDs"))
    #expect(registry.containsTag(named: "whichOther") == false)
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
    let executor = PerfectCRUDLassoExecutor { datasource, query, _ in
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
        capabilities: { _, _ in .readOnly },
        queryHandler: { _, query, _ in
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

// MARK: - LassoInlineRequest -Host array parsing

@Test func inlineRequestParsesHostArrayIntoHostOverride() throws {
    // Real corpus shape (TS_lasso9, every page): var(host_array) =
    // array(-datasource='MySQLDS', -name='<ip>', -username=..., -password=...)
    // passed as -host=$host_array to every inline() call.
    let hostArray = LassoValue.array([
        .pair(.string("datasource"), .string("MySQLDS")),
        .pair(.string("name"), .string("192.168.1.50")),
        .pair(.string("port"), .integer(3307)),
        .pair(.string("username"), .string("dbuser")),
        .pair(.string("password"), .string("dbpass")),
        .pair(.string("schema"), .string("catalog")),
    ])
    let request = try LassoInlineRequest(arguments: [
        EvaluatedArgument(label: "host", value: hostArray),
        EvaluatedArgument(label: "table", value: .string("skus")),
        EvaluatedArgument(label: "findall", value: .boolean(true)),
    ])
    #expect(request.hostOverride == LassoInlineHostOverride(
        dataSource: "MySQLDS", name: "192.168.1.50", port: 3307,
        username: "dbuser", password: "dbpass", schema: "catalog"
    ))

    // -Host's own field labels must not leak into criteria/fieldAssignments
    // as bogus field names (reservedNames covers "host"/"datasource").
    #expect(request.criteria == [])
}

@Test func inlineRequestHostArrayFieldLabelsAreCaseInsensitive() throws {
    let hostArray = LassoValue.array([
        .pair(.string("DataSource"), .string("FileMakerDS")),
        .pair(.string("Name"), .string("fm.internal")),
    ])
    let request = try LassoInlineRequest(arguments: [
        EvaluatedArgument(label: "host", value: hostArray),
    ])
    #expect(request.hostOverride == LassoInlineHostOverride(
        dataSource: "FileMakerDS", name: "fm.internal", port: nil,
        username: nil, password: nil, schema: nil
    ))
}

@Test func inlineRequestHostArrayMissingDataSourceYieldsNoOverride() throws {
    // -Name with no -DataSource isn't a usable override -- falls through
    // to the pre-configured alias-lookup path unchanged, per
    // parseHostOverride's doc comment.
    let hostArray = LassoValue.array([
        .pair(.string("name"), .string("192.168.1.50")),
    ])
    let request = try LassoInlineRequest(arguments: [
        EvaluatedArgument(label: "host", value: hostArray),
    ])
    #expect(request.hostOverride == nil)
}

@Test func inlineRequestHostArrayMissingNameYieldsNoOverride() throws {
    let hostArray = LassoValue.array([
        .pair(.string("datasource"), .string("MySQLDS")),
    ])
    let request = try LassoInlineRequest(arguments: [
        EvaluatedArgument(label: "host", value: hostArray),
    ])
    #expect(request.hostOverride == nil)
}

@Test func inlineRequestHostArrayIgnoresUnknownFieldLabels() throws {
    let hostArray = LassoValue.array([
        .pair(.string("datasource"), .string("MySQLDS")),
        .pair(.string("name"), .string("192.168.1.50")),
        .pair(.string("bogusfield"), .string("ignored")),
    ])
    let request = try LassoInlineRequest(arguments: [
        EvaluatedArgument(label: "host", value: hostArray),
    ])
    #expect(request.hostOverride == LassoInlineHostOverride(
        dataSource: "MySQLDS", name: "192.168.1.50", port: nil,
        username: nil, password: nil, schema: nil
    ))
}

@Test func inlineRequestWithNoHostArgumentHasNilHostOverride() throws {
    let request = try LassoInlineRequest(arguments: [
        EvaluatedArgument(label: "database", value: .string("catalog")),
        EvaluatedArgument(label: "table", value: .string("skus")),
        EvaluatedArgument(label: "findall", value: .boolean(true)),
    ])
    #expect(request.hostOverride == nil)
}

@Test func inlineRequestHostArgumentThatIsNotAnArrayYieldsNoOverride() throws {
    // Real Lasso also documents -Host='inherit' (a bare string) --
    // deliberately unimplemented; must not crash or misparse into a
    // bogus override.
    let request = try LassoInlineRequest(arguments: [
        EvaluatedArgument(label: "host", value: .string("inherit")),
    ])
    #expect(request.hostOverride == nil)
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
    let executor = PerfectFileMakerLassoExecutor { _, _, _, _ in
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
    let executor = PerfectFileMakerLassoExecutor { _, _, _, _ in
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
    let executor = PerfectFileMakerLassoExecutor { _, _, _, _ in
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
    let executor = PerfectFileMakerLassoExecutor(allowWrites: false) { _, _, _, _ in
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
    let executor = PerfectFileMakerLassoExecutor(allowWrites: true) { _, _, _, _ in
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
    let executor = PerfectFileMakerLassoExecutor(allowWrites: true) { query, _, _, _ in
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
    let executor = PerfectFileMakerLassoExecutor(allowWrites: true) { _, _, _, _ in
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
    let executor = PerfectFileMakerLassoExecutor { query, _, _, _ in
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
    let executor = PerfectFileMakerLassoExecutor { query, _, _, _ in
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
    let executor = PerfectFileMakerLassoExecutor { query, _, _, _ in
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
    let executor = PerfectFileMakerLassoExecutor { _, _, _, _ in
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
    let executor = PerfectFileMakerLassoExecutor { query, _, _, _ in
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
    let executor = PerfectFileMakerLassoExecutor(allowWrites: true) { query, _, _, _ in
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
    let executor = PerfectFileMakerLassoExecutor(allowWrites: true) { query, _, _, _ in
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
    let executor = PerfectFileMakerLassoExecutor(allowWrites: true) { query, _, _, _ in
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
    let executor = PerfectFileMakerLassoExecutor { _, kind, datasource, _ in
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
    let executor = PerfectFileMakerLassoExecutor { _, _, _, _ in
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
    let executor = PerfectFileMakerLassoExecutor(allowWrites: false) { _, _, _, _ in
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
    let executor = PerfectFileMakerLassoExecutor(baseURL: "http://203.0.113.10:80") { _, _, _, _ in
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
        capabilities: { _, _ in .full },
        queryHandler: { _, _, _ in DynamicResult(rows: [], statement: "SELECT ...") },
        mutationHandler: { datasource, mutation, _ in
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
        capabilities: { _, _ in .full },
        queryHandler: { _, _, _ in DynamicResult(rows: [], statement: "") },
        rawSQLHandler: { datasource, sql, _ in
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
        queryHandler: { _, _, _ in DynamicResult(rows: [], statement: "") },
        mutationHandler: { _, mutation, _ in DynamicResult(rows: [], affectedRows: 1, statement: "") },
        rawSQLHandler: { _, sql, _ in DynamicResult(rows: [], statement: sql.sql) }
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
        capabilities: { _, _ in .full },
        queryHandler: { datasource, _, _ in
            throw LassoDatabaseActionError(kind: .search, datasource: datasource, underlying: ConnectorFailure.unavailable)
        },
        mutationHandler: { datasource, mutation, _ in
            let kind: LassoDatabaseActionFailureKind = switch mutation.action {
            case .insert: .add
            case .update: .update
            case .delete: .delete
            }
            throw LassoDatabaseActionError(kind: kind, datasource: datasource, underlying: ConnectorFailure.unavailable)
        },
        rawSQLHandler: { datasource, _, _ in
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
        capabilities: { _, _ in .full },
        queryHandler: { _, _, _ in throw LassoRecoverableError(state) }
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
        queryHandler: { _, _, _ in DynamicResult(rows: [], statement: "") }
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
        queryHandler: { _, _, _ in throw ProgrammerError.unexpected }
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

// MARK: - Staticarray literals `(: ... )`

@Test func staticarrayLiteralParsesAsAnOrdinaryArrayValue() async throws {
    // Ch. "Literals" > "Staticarray Literals": "an open parenthesis
    // immediately followed by a colon, then zero or more comma-delimited
    // expressions, ending with the closing parenthesis" -- the Guide's
    // own worked example. This codebase already treats real Lasso's
    // distinct staticarray type as equivalent to its own .array runtime
    // value everywhere else (no separate immutable-array type), so this
    // literal desugars straight into the same array(...) call shape.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        "[(: 1, 2, 'hello')->size]/[(: 1, 2, 'hello')->get(3)]",
        context: &context
    )
    #expect(output == "3/hello")
}

@Test func emptyStaticarrayLiteralParsesAsAnEmptyArray() async throws {
    // "zero or more comma-delimited expressions" -- an empty list is
    // explicitly documented as valid.
    var context = LassoContext()
    let output = try await LassoRenderer().render("[(:)->size]", context: &context)
    #expect(output == "0")
}

@Test func staticarrayLiteralWorksAsAWithInSourceMatchingRealCorpusShape() async throws {
    // Real corpus shape (zeroloop/ds LassoApp's own _init.lasso, seen
    // live in TS_lasso9's index copy 2.lasso and previously in the
    // "scrubs" corpus): `with file in (: 'a.lasso', 'b.lasso') do { ... }`
    // spanning multiple lines, no trailing comma issue, previously
    // failed entirely with unsupportedExpression(":") since a bare `:`
    // right after `(` fell through to `.unknown(":")`.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        """
        <?lassoscript
        with file in (:
            'sequential.lasso',
            'tables.lasso',
            'activerow.lasso'
        ) do {
            #file + ';'
        }
        ?>
        """,
        context: &context
    )
    #expect(output == "sequential.lasso;tables.lasso;activerow.lasso;")
}

@Test func parenthesizedGroupingStillWorksAlongsideTheStaticarrayLiteralFix() async throws {
    // Regression guard: an ordinary parenthesized expression `(x)` --
    // where the very next token after `(` is NOT a bare colon -- must
    // keep parsing exactly as before.
    var context = LassoContext(globals: ["x": .integer(5)])
    let output = try await LassoRenderer().render("[(($x + 1) * 2)]", context: &context)
    #expect(output == "12")
}

@Test func typeConstraintDoubleColonStillWorksAlongsideTheStaticarrayLiteralFix() async throws {
    // Regression guard: `::` (type constraint, e.g. inside a define
    // signature) is a completely different token from a bare `:`
    // immediately after `(` -- must be unaffected.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        """
        <?lassoscript
        define typedEcho(n::integer) => { return(#n + 1) }
        ?>
        [typedEcho(41)]
        """,
        context: &context
    ).trimmingCharacters(in: .whitespacesAndNewlines)
    #expect(output == "42")
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

    // Session_AddVariable/Session_RemoveVariable: real Lasso 8.5 longhand
    // for the same session_addvar/session_removevar this adapter already
    // registered — real corpus (TS_lasso9, 21/60 files, the single most
    // prevalent gap found live-crawling that site) uses only the
    // longhand, previously unknownFunction.
    let longhandProvider = SessionProvider()
    var longhandContext = LassoContext(sessionProvider: longhandProvider)
    let longhandOutput = try await LassoRenderer().render(
        "[session_start('cart')][var(cartvalue = 'open')][session_AddVariable: -Name = 'cart', 'cartvalue'][cartvalue]",
        context: &longhandContext
    )
    #expect(longhandOutput == "open")
    #expect(longhandProvider.persisted["cart"]?["cartvalue"] == .string("open"))

    let longhandRemoveProvider = SessionProvider()
    var longhandRemoveContext = LassoContext(sessionProvider: longhandRemoveProvider)
    _ = try await LassoRenderer().render(
        "[session_start('cart')][var(a = 'x')][session_AddVariable:'cart','a'][session_RemoveVariable:'cart','a']",
        context: &longhandRemoveContext
    )
    #expect(longhandRemoveProvider.persisted["cart"] == nil)
}

@Test func varSetBracketColonCallAliasesVarAssignment() async throws {
    // Real corpus shape (TS_lasso9, 15/60 files): `[var_set:'name' =
    // value]` -- Lasso 8.5's original free-tag name for what Lasso 9
    // shortened to `Var`/`Variable`, previously unknownFunction("var_set").
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        "[var_set:'tsid' = 42][var:'tsid']",
        context: &context
    )
    #expect(output == "42")

    // Global scope, matching plain `var` -- readable from a nested inline
    // block without re-declaring, not just the same top-level scope.
    var globalScopeContext = LassoContext(inlineProvider: LassoInMemoryInlineProvider(tables: [
        "skus": [LassoDataRow(["mfr_style_no": .string("A")])],
    ]))
    let globalScopeOutput = try await LassoRenderer().render(
        "[var_set:'greeting' = 'hi'][inline(-database='catalog',-table='skus',-search)][records][var:'greeting'][/records][/inline]",
        context: &globalScopeContext
    )
    #expect(globalScopeOutput == "hi")
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

// MARK: - handle / handle_failure

@Test func handleRunsAfterNormalCompletionOfItsEnclosingBlock() async throws {
    // Ch. "Error Handling" > "handle and handle_failure": "the code
    // inside the handle methods will be conditionally executed after the
    // capture block is executed" -- registered inside an `if` block here
    // (any block, per the Guide's own wording, not just a page), runs
    // once that block finishes, its own output appended normally since
    // nothing failed.
    // Registering handle produces no output of its own at the point it's
    // written -- its capture's text only appears once the ENCLOSING
    // block (`if`, here) finishes rendering, appended after everything
    // else that block already produced.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        "before-[if(true)]during-mid[handle => {'-H'}][/if]-after",
        context: &context
    )
    #expect(output == "before-during-mid-H-after")
}

@Test func handleRunsOnAThrownErrorAndObservesItViaErrorMsgWithoutSwallowingIt() async throws {
    // The real evidenced corpus need (zeroloop/ds's own _init.lasso,
    // Task #178): handle registered before a call that fails, using
    // error_msg to describe what happened -- handle must NOT swallow the
    // failure (`protect` stays the only thing that does that); the same
    // error still propagates afterward.
    var natives = LassoNativeRegistry()
    natives.register("fail_with_db_error") { _, _ in
        throw LassoRecoverableError(LassoErrorState(code: 42, message: "Add failed", kind: "add"))
    }
    var context = LassoContext(natives: natives)
    await #expect(throws: LassoRecoverableError(LassoErrorState(code: 42, message: "Add failed", kind: "add"))) {
        _ = try await LassoRenderer().render(
            "[handle => {var(sawError) = error_msg}][fail_with_db_error]",
            context: &context
        )
    }
    #expect(context.value(for: "sawError", scope: .global) == .string("Add failed"))
}

@Test func handleConditionSkipsExecutionWhenFalse() async throws {
    // "can take a single parameter that is a conditional expression,
    // defaulting to true. If the conditional expression evaluates as
    // true, the code in the given capture block is executed."
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        "[handle(false) => {'H'}]visible",
        context: &context
    )
    #expect(output == "visible")
}

@Test func handleFailureOnlyRunsWhenItsEnclosingBlockActuallyFailed() async throws {
    var natives = LassoNativeRegistry()
    natives.register("fail_with_db_error") { _, _ in
        throw LassoRecoverableError(LassoErrorState(code: 1, message: "boom", kind: "custom"))
    }
    var cleanContext = LassoContext()
    let cleanOutput = try await LassoRenderer().render(
        "[handle_failure => {'H'}]clean",
        context: &cleanContext
    )
    #expect(cleanOutput == "clean")

    var failingContext = LassoContext(natives: natives)
    await #expect(throws: LassoRecoverableError(LassoErrorState(code: 1, message: "boom", kind: "custom"))) {
        _ = try await LassoRenderer().render(
            "[handle_failure => {var(ranHandleFailure) = true}][fail_with_db_error]",
            context: &failingContext
        )
    }
    #expect(failingContext.value(for: "ranHandleFailure", scope: .global) == .boolean(true))
}

@Test func multipleHandlesRunInRegistrationOrder() async throws {
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        "[handle => {'first;'}][handle => {'second;'}]body-",
        context: &context
    )
    #expect(output == "body-first;second;")
}

@Test func handleRegisteredInsideAWithDoLoopIterationRunsOncePerIterationMatchingRealCorpusShape() async throws {
    // Real corpus shape (zeroloop/ds LassoApp's own _init.lasso): handle
    // registered fresh each loop iteration, only observing/logging that
    // ONE iteration's own outcome -- not accumulating across iterations,
    // and not leaking into a later iteration's own handle registration.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        """
        <?lassoscript
        with file in array('a.lasso', 'b.lasso') do {
            handle => {
                ' [handled ' + #file + ']'
            }
            #file + ';'
        }
        ?>
        """,
        context: &context
    )
    #expect(output == "a.lasso; [handled a.lasso]b.lasso; [handled b.lasso]")
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

@Test func failThrowsARecoverableErrorProtectCatchesMatchingTheLanguageGuidesOwnWorkedExample() async throws {
    // Ch. 19 "Fail Tags": `[Fail: -1, 'An unrecoverable error occurred']`
    // — code+message form. `fail` with no enclosing `protect` propagates
    // as an unhandled LassoRecoverableError (real Lasso: "To report an
    // unrecoverable error" — Handle/Handle_Error blocks, which would
    // otherwise catch it, are a separate, deliberately deferred stage —
    // see ErrorHandling.swift's own doc comment).
    var protectedContext = LassoContext()
    let protectedOutput = try await LassoRenderer().render(
        "before-[protect]during-[fail(-1, 'An unrecoverable error occurred')]-unreached[/protect]-after-[error_currenterror(-errorcode)]: [error_currenterror]",
        context: &protectedContext
    )
    #expect(protectedOutput == "before--after--1: An unrecoverable error occurred")

    var unprotectedContext = LassoContext()
    await #expect(throws: LassoRecoverableError(LassoErrorState(code: -1, message: "boom", kind: "fail"))) {
        _ = try await LassoRenderer().render("[fail(-1, 'boom')]", context: &unprotectedContext)
    }
}

@Test func failWithOnlyAMessageDefaultsToTheGenericCustomCode() async throws {
    // lassoguide.com's Lasso 9 "Error Handling": `fail(msg::string)` —
    // the message-only alternate form Ch. 19's own 8.5-era doc doesn't
    // have; defaults to -1, the same generic-custom-error code the
    // Guide's own two-arg worked example uses.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        "[protect][fail('just a message')][/protect][error_currenterror(-errorcode)]: [error_currenterror]",
        context: &context
    )
    #expect(output == "-1: just a message")
}

@Test func failIfOnlyTriggersWhenItsConditionIsTrueMatchingTheLanguageGuidesOwnWorkedExample() async throws {
    // Ch. 19: `[Fail_If: (Found_Count == 0), (Error_NoRecordsFound:
    // -ErrorCode), (Error_NoRecordsFound)]` — condition, code, message.
    // Exercised here with a plain boolean condition rather than
    // Found_Count specifically, since Error_NoRecordsFound is itself
    // documented as deprecated in favor of a Found_Count == 0 check
    // (Ch. 19's own "Note" right after Table 4).
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        "[protect][fail_if(1 == 2, -5, 'should not fire')][/protect][error_currenterror(-errorcode)]|" +
        "[protect][fail_if(1 == 1, -5, 'should fire')][/protect][error_currenterror(-errorcode)]",
        context: &context
    )
    #expect(output == "0|-5")
}

@Test func errorPushAndErrorPopRestoreThePreviousErrorConditionMatchingTheirOwnDocumentedContract() async throws {
    // Ch. 19: "[Error_Push] Pushes the current error condition onto a
    // stack and resets the current error code and error message."
    // "[Error_Pop] Restores the last error condition stored using
    // [Error_Push]." — real corpus pattern: preventing a preexisting
    // error from bleeding into a protect block.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        "[error_seterrorcode(99)][error_seterrormessage('outer')]" +
        "[error_push][error_code]/[error_msg]|" +
        "[error_seterrorcode(1)][error_seterrormessage('inner')][error_code]/[error_msg]|" +
        "[error_pop][error_code]/[error_msg]",
        context: &context
    )
    // Resets to the SAME `.noError` state (`code: 0, message: "No
    // Error"`) `Runtime.swift` already uses everywhere else — not a
    // truly blank message.
    #expect(output == "0/No Error|1/inner|99/outer")
}

@Test func errorResetClearsTheCurrentErrorCaseInsensitivelyMatchingTheLasso9WorkedExample() async throws {
    // Ch. 19's own prose says "[Error_Reset]... resets the error message
    // to blank" — but lassoguide.com's Lasso 9 "Error Handling" page has
    // its OWN worked example for the identical operation showing "No
    // error" instead (`error_reset; error_code + ': ' + error_msg //
    // => 0: No error`), directly contradicting the 8.5 prose. Matches
    // this project's established practice of preferring a worked
    // example over prose when the two disagree (see e.g. the Math_Div/
    // String_ReplaceRegExp defects found earlier in this project) —
    // also keeps this consistent with the already-tested default
    // `error_currenterror` state (`errorCurrentErrorDefaultsToNoErrorAndInlineFramesUpdateIt`,
    // "No Error/0"), which `error_reset` reuses via the same shared
    // `context.clearError()`/`.noError` this codebase already has.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        "[error_seterrorcode(-1)][error_seterrormessage('Too slow')][error_code]: [error_msg]|" +
        "[error_reset][error_code]: [error_msg]",
        context: &context
    )
    #expect(output == "-1: Too slow|0: No Error")
}

@Test func namedErrorTypeTagsReturnTheirOwnFixedCodeOrMessageIndependentOfCurrentErrorState() async throws {
    // Table 4 "Error Type Tags" are named CONSTANT accessors, not
    // `currentError` state — bare returns the fixed message, `-ErrorCode`
    // the fixed code, verified against Appendix A's own numeric table
    // (p.823 Action/Security Errors) and Table 4's own descriptions.
    // Matches the Guide's own chaining worked example:
    // `[Error_SetErrorCode: (Error_AddError: -ErrorCode)]`.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        "[error_adderror(-errorcode)]|[error_deleteerror(-errorcode)]|[error_updateerror(-errorcode)]|" +
        "[error_fieldrestriction(-errorcode)]|[error_columnrestriction(-errorcode)]|" +
        "[error_nopermission(-errorcode)]|[error_invaliddatabase(-errorcode)]|" +
        "[error_invalidpassword(-errorcode)]|[error_invalidusername(-errorcode)]|[error_noerror(-errorcode)]",
        context: &context
    )
    #expect(output == "-9959|-9957|-9958|-9960|-9960|-9961|-9962|-9963|-9964|0")

    var chainedContext = LassoContext()
    let chainedOutput = try await LassoRenderer().render(
        "[error_seterrorcode(error_adderror(-errorcode))][error_seterrormessage(error_adderror)][error_code]: [error_msg]",
        context: &chainedContext
    )
    #expect(chainedOutput == "-9959: An error occurred during an -Add action.")
}

@Test func lasso9StyleErrorCodeAndErrorMsgConstantsMatchLassoguideComsOwnTable() async throws {
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        "[error_code_divideByzero]/[error_msg_divideByzero]|[error_code_filenotfound]/[error_msg_filenotfound]",
        context: &context
    )
    #expect(output == "-9950/Divide by Zero|404/File not found")
}

@Test func divisionByZeroThrowsARecoverableErrorInsteadOfCrashingOrProducingInfinity() async throws {
    // Previously: `.decimal` division silently produced `inf`/`nan`,
    // `.integer` division crashed the process outright (Swift traps on
    // integer divide-by-zero) — neither matches the documented,
    // catchable `error_code_divideByZero`. A non-numeric right operand
    // (e.g. dividing by an empty string) must ALSO be caught, not just
    // a literal `0` — regression-guards the `right.number ?? 0` fix
    // (comparing the raw Optional directly would have let this
    // specific case slip through).
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        "[protect][10 / 0][/protect][error_currenterror(-errorcode)]: [error_currenterror]|" +
        "[protect][10.5 / 0][/protect][error_currenterror(-errorcode)]: [error_currenterror]|" +
        "[protect][10 / '']|[/protect][error_currenterror(-errorcode)]: [error_currenterror]",
        context: &context
    )
    #expect(output == "-9950: Divide by Zero|-9950: Divide by Zero|-9950: Divide by Zero")
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

@Test func bareReturnAndYieldWorkAsATernaryActionClause() async throws {
    // `ScriptBodyParser.normalizeReturn` rewrites a bare (paren-less)
    // `return X`/`yield X` into `return(X)`/`yield(X)` -- but only by
    // checking whether the WHOLE STATEMENT TEXT starts with "return "/
    // "yield " (a `hasPrefix` check). When bare `return`/`yield` appears
    // as a ternary short-form's action clause instead of the whole
    // statement (`x == 1 ? return true`, no `|` else-branch), the
    // rewrite never fires, and the bare keyword falls through to the
    // generic juxtaposition/string-concatenation sugar (an unrelated
    // undefined variable named "return", concatenated with "true")
    // instead of ever invoking the real `register("return")` native
    // function. Confirmed real via the Language Guide's own canonical
    // `contains()` worked example -- see the `arrayForEach...` test
    // below whose doc comment first flagged this, independent of
    // Captures/forEach entirely (`x == 1 ? return true` alone
    // reproduces it with a plain `define`).
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        """
        <?lassoscript
        define testit(x) => {
            x == 1 ? return true
            return false
        }
        ?>
        [testit(1)]|[testit(2)]
        """,
        context: &context
    ).trimmingCharacters(in: .whitespacesAndNewlines)
    #expect(output == "true|false", "Bare `return` in a ternary's action clause must actually invoke return")

    var yieldContext = LassoContext()
    let yieldOutput = try await LassoRenderer().render(
        """
        <?lassoscript
        define generator() => {
            loop(-count=3) => {
                loop_count == 2 ? yield 'two'
            }
        }
        ?>
        [generator()]
        """,
        context: &yieldContext
    ).trimmingCharacters(in: .whitespacesAndNewlines)
    #expect(yieldOutput == "two", "Bare `yield` in a ternary's action clause must actually invoke yield")

    var elseBranchContext = LassoContext()
    let elseBranchOutput = try await LassoRenderer().render(
        """
        <?lassoscript
        define testit2(x) => {
            x == 1 ? return true | return false
        }
        ?>
        [testit2(1)]|[testit2(2)]
        """,
        context: &elseBranchContext
    ).trimmingCharacters(in: .whitespacesAndNewlines)
    #expect(elseBranchOutput == "true|false", "Bare `return` must work in both the `?` and `|` branches")

    // Non-regression: the already-working parenthesized form must be untouched.
    var parenContext = LassoContext()
    let parenOutput = try await LassoRenderer().render(
        """
        <?lassoscript
        define testit3(x) => {
            x == 1 ? return(true)
            return(false)
        }
        ?>
        [testit3(1)]|[testit3(2)]
        """,
        context: &parenContext
    ).trimmingCharacters(in: .whitespacesAndNewlines)
    #expect(parenOutput == "true|false", "Parenthesized return(...) in a ternary action clause must keep working")
}

@Test func valuelessBareReturnAsATernaryActionStillReturnsVoidWithoutCorruptingParsing() async throws {
    // `register("return")`/`register("yield")` (Runtime.swift) already
    // default a MISSING argument to `.void` -- a bare `return`/`yield`
    // with no value at all is a real, supported shape, not just the
    // valued form `return X` this fix started from. Found by code
    // review of the value-form fix above: naively assuming a value
    // always follows a bare `return`/`yield` in ternary position either
    // throws (nothing follows at all -- the parser tries to parse the
    // statement's own end-of-input as a value) or, worse, silently eats
    // the ternary's own `|` separator (single `|` isn't a registered
    // binary operator, so it falls to the prefix parser's generic
    // symbol catch-all as a bogus value), corrupting the whenFalse
    // branch entirely. Both shapes below reproduce the two ways that
    // went wrong.
    var noElseContext = LassoContext()
    let noElseOutput = try await LassoRenderer().render(
        """
        <?lassoscript
        define testit5(x) => {
            x == 1 ? return
            return('not-returned')
        }
        ?>
        [testit5(1)]|[testit5(2)]
        """,
        context: &noElseContext
    ).trimmingCharacters(in: .whitespacesAndNewlines)
    #expect(noElseOutput == "|not-returned", "A valueless bare return with nothing following it must halt with void, not throw")

    var withElseContext = LassoContext()
    let withElseOutput = try await LassoRenderer().render(
        """
        <?lassoscript
        define testit6(x) => {
            x == 1 ? return | return('fallback-branch-ran')
        }
        ?>
        [testit6(1)]|[testit6(2)]
        """,
        context: &withElseContext
    ).trimmingCharacters(in: .whitespacesAndNewlines)
    #expect(withElseOutput == "|fallback-branch-ran", "A valueless bare return in the `?` branch must not swallow the `|` separator")
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

@Test func stringValidationMembersMatchTheLanguageGuidesOwnWorkedExampleCaseInsensitively() async throws {
    // Lasso 8.5 Language Guide Ch. 25 Table 7, confirmed via the Guide's
    // own worked example verbatim (testString = 'A short string'):
    // BeginsWith/EndsWith/Contains/Equals are all documented case
    // INSENSITIVE -- an earlier version of `->Contains` used Swift's raw
    // case-sensitive `String.contains`, contradicting its own sibling
    // members (`->BeginsWith`/`->EndsWith`/`->Equals`, all newly added
    // here with the correct case-insensitive behavior); caught while
    // verifying those siblings against this same page and fixed
    // alongside them.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        """
        [var(testString = 'A short string')]
        beginsA=[$testString->beginsWith('a')]|
        beginsPhrase=[$testString->beginsWith('A short')]|
        beginsFalse=[$testString->beginsWith('string')]|
        ends=[$testString->endsWith('string')]|
        contains=[$testString->contains('short')]|
        containsMixedCase=[$testString->contains('SHORT')]|
        equals=[$testString->equals('a short string')]
        """,
        context: &context
    )
    #expect(output.contains("beginsA=true"))
    #expect(output.contains("beginsPhrase=true"))
    #expect(output.contains("beginsFalse=false"))
    #expect(output.contains("ends=true"))
    #expect(output.contains("contains=true"))
    #expect(output.contains("containsMixedCase=true"))
    #expect(output.contains("equals=true"))
}

@Test func stringCompareIsThreeWayCaseInsensitiveByDefaultCaseSensitiveWithFlag() async throws {
    // Ch. 25 Table 7: "[String->Compare] ... returns 0 if the parameter
    // is equal to the string, 1 if the characters in the string are
    // bitwise greater than the parameter, and -1 if... less... Comparison
    // is case insensitive by default. An optional -Case parameter makes
    // the comparison case sensitive." NOT tested against the Guide's own
    // "[$testString->(Compare: 'a short string', -Case)] -> False" line
    // for this exact scenario -- that line is internally inconsistent
    // (an integer-returning tag's worked example showing the literal
    // word "False", not a 0/1/-1 value) and looks like the same class of
    // transcription defect already confirmed once in this project
    // (Math_Div's page-370 examples). Verified instead with
    // self-computed, unambiguous cases.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        "[('abc')->compare('abc')]|[('abc')->compare('abd')]|[('abd')->compare('abc')]|" +
            "[('A short string')->compare('a short string')]|" +
            "[('A short string')->compare('a short string', -Case)]",
        context: &context
    )
    let parts = output.components(separatedBy: "|")
    #expect(parts[0] == "0")
    #expect(parts[1] == "-1")
    #expect(parts[2] == "1")
    // Case-insensitive by default: equal.
    #expect(parts[3] == "0")
    // -Case forces case-sensitive comparison: 'A' (0x41) sorts before
    // 'a' (0x61) bitwise, so the base string is "less than" the parameter.
    #expect(parts[4] == "-1")
}

@Test func stringFindReturnsAOneBasedPositionOrZeroForAMiss() async throws {
    // Ch. 25 Table 9: "Returns the position at which the first parameter
    // is found within the string or 0 if the first parameter is not
    // found." Distinct from Array->Find (returns an array of all
    // matches) -- dispatch is keyed on `(base, name)` together so the
    // two don't collide.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        "[('A Short String')->find('Short')]|[('A Short String')->find('zzz')]",
        context: &context
    )
    #expect(output == "3|0")
}

@Test func stringGetReturnsASingleCharacterAtAOneBasedPosition() async throws {
    // Ch. 25 Table 9 worked example: ['Alpha'->(Get: 3)] -> 'p'.
    var context = LassoContext()
    let output = try await LassoRenderer().render("[('Alpha')->get(3)]", context: &context)
    #expect(output == "p")
}

@Test func stringPadLeadingAndPadTrailingPadToALengthWithADefaultOrCustomCharacter() async throws {
    // Ch. 25 Table 3: pads to a specified length with a pad character
    // (defaults to space); a string already at or past the target
    // length is left unchanged (mutating members return the invocant
    // unmodified rather than truncating).
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        """
        [var(a = 'ab')][$a->padLeading(5, '0')]a=[$a]|
        [var(b = 'ab')][$b->padTrailing(5, '0')]b=[$b]|
        [var(c = 'ab')][$c->padLeading(4)]c=[$c]|
        [var(d = 'abcdef')][$d->padLeading(3, '0')]d=[$d]
        """,
        context: &context
    )
    #expect(output.contains("a=000ab"))
    #expect(output.contains("b=ab000"))
    #expect(output.contains("c=  ab"))
    #expect(output.contains("d=abcdef"))
}

@Test func stringRemoveLeadingAndRemoveTrailingStripEveryRepeatedInstance() async throws {
    // Ch. 25 Table 3: "Removes ALL instances of the parameter from the
    // beginning/end" -- repeated, not just a single occurrence, distinct
    // from `->Trim` (whitespace-only).
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        "[var(s = '**A Short String**')][$s->removeLeading('*')][$s->removeTrailing('*')]result=[$s]",
        context: &context
    )
    #expect(output == "result=A Short String")
}

@Test func stringReverseReversesTheEntireString() async throws {
    var context = LassoContext()
    let output = try await LassoRenderer().render("[var(s = 'Hello')][$s->reverse]result=[$s]", context: &context)
    #expect(output == "result=olleH")
}

@Test func stringTitlecaseCapitalizesTheFirstLetterOfEachWord() async throws {
    // Ch. 25 Table 5: "Converts the string to titlecase with the first
    // character of each word capitalized." Word boundaries are
    // whitespace (no locale-parameter support implemented here).
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        "[var(s = 'hello WORLD from lasso')][$s->titlecase]result=[$s]",
        context: &context
    )
    #expect(output == "result=Hello World From Lasso")
}

@Test func stringIsFamilyValidatesTheWholeStringMatchingTheLanguageGuidesOwnWorkedExamples() async throws {
    // Ch. 25 Table 10, confirmed via the Guide's own worked examples
    // verbatim. Empty-string inputs deliberately return False (not the
    // vacuously-true default Swift's `allSatisfy` would give on an empty
    // collection) -- see the registration's own doc comment for why.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        "[String_IsAlpha('word')]|[String_IsAlphaNumeric('word')]|[String_IsLower('word')]|" +
            "[String_IsNumeric('word')]|[String_IsUpper('word')]|" +
            "[String_IsAlpha('2468')]|[String_IsAlphaNumeric('2468')]|[String_IsNumeric('2468')]|" +
            "[String_IsDigit('9')]|[String_IsHexDigit('a')]|[String_IsPunctuation('.')]|[String_IsSpace(' ')]|" +
            "[String_IsAlpha('')]",
        context: &context
    )
    let parts = output.components(separatedBy: "|")
    #expect(parts == [
        "true", "true", "true", "false", "false",
        "false", "true", "true",
        "true", "true", "true", "true",
        "false",
    ])
}

@Test func stringLengthIsASynonymForSizeAndStringEndsWithMatchesTheMemberForm() async throws {
    // Ch. 25 Table 10 worked example: String_Length('A Short String') ==
    // 'A Short String'->Size == 14.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        "[String_Length('A Short String')]|[('A Short String')->size]|" +
            "[String_EndsWith('A Short String', -Find='String')]",
        context: &context
    )
    #expect(output == "14|14|true")
}

@Test func regExpConstructorAndAccessorsMatchTheLanguageGuidesOwnWorkedExample() async throws {
    // Lasso 8.5 Language Guide Ch. 26 Table 7/8 (pp. 350-351), verified
    // directly against the PDF including its own worked example
    // (`$MyRegExp` built from `-Find='[aeiou]', -Replace='x', -IgnoreCase`).
    // `->FindPattern`/`->ReplacePattern`/`->Input`/`->IgnoreCase` are
    // implemented as read-only getters here (see NativeTypes.swift's own
    // doc comment on `makeRegExpType()` for why a setter needs the same
    // treatment `Date->Add`/`->Subtract` required after their aliasing
    // bug, deferred to a follow-up).
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        """
        [var(re = RegExp(-Find='[aeiou]', -Replace='x', -IgnoreCase))]
        FindPattern: [$re->findPattern]
        ReplacePattern: [$re->replacePattern]
        IgnoreCase: [$re->ignoreCase]
        GroupCount: [$re->groupCount]
        """,
        context: &context
    )
    #expect(output.contains("FindPattern: [aeiou]"))
    #expect(output.contains("ReplacePattern: x"))
    #expect(output.contains("IgnoreCase: true"))
    #expect(output.contains("GroupCount: 0"))
}

@Test func regExpReplaceAllMatchesTheLanguageGuidesOwnVowelReplacementWorkedExample() async throws {
    // Ch. 26 p.352, exact worked example (vowel-to-x substitution).
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        """
        [var(re = RegExp(-Find='[aeiou]', -Replace='x', -IgnoreCase))]
        [$re->replaceAll(-Input='The quick brown fox jumped over the lazy dog.')]
        """,
        context: &context
    )
    #expect(output.trimmingCharacters(in: .whitespacesAndNewlines) == "Thx qxxck brxwn fxx jxmpxd xvxr thx lxzy dxg.")
}

@Test func regExpReplaceAllSupportsGroupPlaceholders() async throws {
    // Ch. 26 p.352: "The replacement pattern can reference groups from
    // the input using \\1 through \\9." Uses a simpler pattern than the
    // Guide's own phone-number example (which needs several `\d`/`\(`
    // escapes) purely to keep the Swift-literal -> Lasso-source-literal
    // -> regex-template escaping chain in this test legible, but
    // exercises the identical group-reference mechanism: two groups,
    // swapped in the replacement.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        "[var(re = RegExp(-Find='(a+)(b+)', -Replace='\\\\2\\\\1'))][$re->replaceAll(-Input='xxaaabbbyy')]",
        context: &context
    )
    #expect(output == "xxbbbaaayy")
}

@Test func regExpReplaceAllSupportsTheDollarSignGroupPlaceholderAlternateForm() async throws {
    // Ch. 26 Table 5, p.349, second Note: "The [RegExp] type also
    // supports $0 and $1 through $9 as replacement symbols" — an
    // alternate to `\1`-`\9`, so it must produce identical output to
    // `regExpReplaceAllSupportsGroupPlaceholders`'s `\2\1` case above.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        "[var(re = RegExp(-Find='(a+)(b+)', -Replace='$2$1'))][$re->replaceAll(-Input='xxaaabbbyy')]",
        context: &context
    )
    #expect(output == "xxbbbaaayy")
}

@Test func regExpReplaceAllSupportsTheDollarSignLiteralEscapeEvenWhenFollowedByADigit() async throws {
    // Ch. 26 Table 5, p.349, second Note: "In order to place a literal
    // $ in a replacement string it is necessary to escape it as \$."
    // Regression test for a real bug: the escaped `$` was previously
    // emitted raw into the NSRegularExpression template, so a digit
    // immediately following it (a realistic case, e.g. escaping a
    // dollar amount) was misread as a `$<digit>` group reference
    // instead of literal text. `\\$5.00` here is the Lasso source
    // text's own `\$` escape (see the Swift-literal -> Lasso-source
    // -> lexer chain documented on `regExpReplaceAllSupportsGroupPlaceholders`
    // above) producing a literal `$5.00`, not a group-1 reference.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        "[var(re = RegExp(-Find='[aeiou]', -Replace='\\\\$5.00'))][$re->replaceFirst(-Input='banana')]",
        context: &context
    )
    #expect(output == "b$5.00nana")
}

@Test func regExpReplaceFirstOnlyReplacesTheFirstMatch() async throws {
    // Ch. 26 Table 9: "[RegExp->ReplaceFirst] Replaces the first
    // occurence of the current find pattern... Uses the same parameters
    // as [RegExp->ReplaceAll]."
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        "[var(re = RegExp(-Find='[aeiou]', -Replace='x', -IgnoreCase))][$re->replaceFirst(-Input='banana')]",
        context: &context
    )
    #expect(output == "bxnana")
}

@Test func regExpSplitMatchesTheLanguageGuidesOwnWordSplittingWorkedExample() async throws {
    // Ch. 26 p.353, exact worked example: splitting on runs of
    // non-word characters yields just the words, no empty/punctuation
    // elements.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        "[var(re = RegExp(-Find='[aeiou]'))][$re->split(-Find='\\\\W+', -Input='The quick brown fox jumped over the lazy dog.')->join(',')]",
        context: &context
    )
    #expect(output == "The,quick,brown,fox,jumped,over,the,lazy,dog")
}

@Test func regExpSplitInterleavesCaptureGroupsBetweenSegmentsWhenTheFindPatternHasGroups() async throws {
    // Ch. 26 p.353, exact worked example: wrapping the split pattern in
    // parentheses interleaves the matched delimiter text itself into the
    // result array between each pair of word segments.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        "[var(re = RegExp(-Find='[aeiou]'))][$re->split(-Find='(\\\\W+)', -Input='ab cd')->join('|')]",
        context: &context
    )
    #expect(output == "ab| |cd")
}

@Test func stringFindRegExpReturnsAFlatArrayOfFullMatchThenEachCaptureGroupPerMatch() async throws {
    // Ch. 26 Table 11 / p.356, exact worked example: a 2-group pattern
    // matching one email address in the source text yields a 3-element
    // flat array (full match, then each group) -- not a nested
    // array-of-arrays-per-match.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        "[String_FindRegExp('Send email to documentation@lassosoft.com.', " +
            "-Find='([A-Za-z0-9_]+)@([A-Za-z0-9_]+\\\\.[A-Za-z0-9_]+)')->join('|')]",
        context: &context
    )
    #expect(output == "documentation@lassosoft.com|documentation|lassosoft.com")
}

@Test func stringFindRegExpFlattensMultipleMatchesIntoOneArrayInOrder() async throws {
    // Ch. 26 p.356, exact worked example: a 1-group pattern ("first
    // character of each word") matching 9 words in the source yields an
    // 18-element flat array (full+group1, full+group1, ... per match, in
    // order) -- confirms the "flat, not nested" contract holds across
    // multiple matches, not just one.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        "[String_FindRegExp('The quick brown fox jumped over a lazy dog.', -Find='([A-Za-z])[A-Za-z]*')->join('|')]",
        context: &context
    )
    #expect(output == "The|T|quick|q|brown|b|fox|f|jumped|j|over|o|a|a|lazy|l|dog|d")
}

@Test func stringReplaceRegExpReturnsAStringMatchingTheLanguageGuidesOwnWorkedExampleNotAnArray() async throws {
    // Ch. 26 Table 11's own description text says this tag "Returns an
    // array..." -- almost certainly a copy-paste artifact from the
    // FindRegExp row just above it (see the registration's own doc
    // comment), since the Guide's own worked example output (p.357) is
    // unambiguously a plain string.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        "[String_ReplaceRegExp('Blue Lake sure is blue today.', " +
            "-Find='[Bb]lue', -Replace='<b>x</b>')]",
        context: &context
    )
    #expect(output == "<b>x</b> Lake sure is <b>x</b> today.")
}

@Test func stringReplaceRegExpOnlyOneFlagLimitsToTheFirstMatch() async throws {
    // Ch. 26 Table 11: "Optional -ReplaceOnlyOne parameter replaces only
    // the first pattern match."
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        "[String_ReplaceRegExp('aaa', -Find='a', -Replace='b', -ReplaceOnlyOne)]",
        context: &context
    )
    #expect(output == "baa")
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
        capabilities: { _, _ in .readOnly },
        queryHandler: { _, query, _ in
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
        capabilities: { _, _ in .readOnly },
        queryHandler: { _, query, _ in
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
        capabilities: { _, _ in .readOnly },
        queryHandler: { _, query, _ in
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
        func send(_ arguments: [EvaluatedArgument], context: LassoContext) async throws -> LassoEmailSendResult {
            recorder.record(arguments)
            return LassoEmailSendResult(value: .string("queued"), jobID: nil)
        }
        // Not exercised by this test — the protocol gained these two
        // methods in Phase C (§4.0/§4.3b/§4.4); every conformer, including
        // test doubles, must implement them regardless of whether a given
        // test cares.
        func compose(_ arguments: [EvaluatedArgument], context: LassoContext) async throws -> LassoValue { .void }
        func mxLookup(_ arguments: [EvaluatedArgument], context: LassoContext) async throws -> LassoValue { .void }
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

@Test func emailComposeThrowsEmailNotConfiguredWhenNoEmailProviderIsWired() async throws {
    // Same dispatch seam as `email_send` (§4.0), now also covering
    // `email_compose` (Phase C, §4.3b) — mirrors
    // `emailSendThrowsEmailNotConfiguredWhenNoEmailProviderIsWired` exactly.
    var context = LassoContext()
    await #expect(throws: LassoRuntimeError.emailNotConfigured) {
        try await LassoRenderer().render(
            "[email_compose: -to='a@example.com', -from='b@example.com', -subject='s', -body='b']",
            context: &context
        )
    }
}

@Test func emailMXLookupThrowsEmailNotConfiguredWhenNoEmailProviderIsWired() async throws {
    var context = LassoContext()
    await #expect(throws: LassoRuntimeError.emailNotConfigured) {
        try await LassoRenderer().render(
            "[email_mxlookup: 'example.com']",
            context: &context
        )
    }
}

@Test func emailComposeDispatchesToTheConfiguredEmailProviderAndReturnsItsResult() async throws {
    // Proves the §4.0 dispatch seam reaches `LassoEmailProvider.compose`
    // end to end, mirroring
    // `emailSendDispatchesToTheConfiguredEmailProviderAndReturnsItsResult`.
    // Uses a test-double conformer returning a real `.object(typeName:
    // "email_compose")` value, then exercises the registered native-type
    // methods (`->data`/`->from`/`->recipients`/`->asString`) against it —
    // proving `NativeTypes.swift`'s `makeEmailComposeType()` and
    // `Runtime.swift`'s `email_compose` free-function registration work
    // together end to end, without depending on `LassoPerfectSMTP` (which
    // has its own, separate end-to-end tests for the real conformer).
    final class EmailProviderRecorder: @unchecked Sendable {
        private(set) var composeCalls: [[EvaluatedArgument]] = []
        func record(_ arguments: [EvaluatedArgument]) { composeCalls.append(arguments) }
    }
    struct EmailProvider: LassoEmailProvider {
        let recorder: EmailProviderRecorder
        func send(_ arguments: [EvaluatedArgument], context: LassoContext) async throws -> LassoEmailSendResult { LassoEmailSendResult(value: .void, jobID: nil) }
        func compose(_ arguments: [EvaluatedArgument], context: LassoContext) async throws -> LassoValue {
            recorder.record(arguments)
            return .object(LassoObjectInstance(typeName: "email_compose", data: [
                "_data": .string("From: b@example.com\r\nTo: a@example.com\r\n\r\nb"),
                "_from": .string("b@example.com"),
                "_recipients": .array([.string("a@example.com")]),
            ]))
        }
        func mxLookup(_ arguments: [EvaluatedArgument], context: LassoContext) async throws -> LassoValue { .void }
    }
    let recorder = EmailProviderRecorder()
    var context = LassoContext(emailProvider: EmailProvider(recorder: recorder))

    let output = try await LassoRenderer().render(
        "[var(message = email_compose(-to='a@example.com', -from='b@example.com', -subject='s', -body='b'))]" +
        "[$message->from]|[$message->recipients->get(1)]|[$message->data->contains('b@example.com')]|[$message->asString->contains('b@example.com')]",
        context: &context
    )

    #expect(recorder.composeCalls.count == 1)
    #expect(output == "b@example.com|a@example.com|true|true")
}

@Test func emailMXLookupDispatchesToTheConfiguredEmailProviderAndReturnsItsResult() async throws {
    struct EmailProvider: LassoEmailProvider {
        func send(_ arguments: [EvaluatedArgument], context: LassoContext) async throws -> LassoEmailSendResult { LassoEmailSendResult(value: .void, jobID: nil) }
        func compose(_ arguments: [EvaluatedArgument], context: LassoContext) async throws -> LassoValue { .void }
        func mxLookup(_ arguments: [EvaluatedArgument], context: LassoContext) async throws -> LassoValue {
            .map([
                "domain": .string(arguments.positionalValue(at: 0)?.outputString ?? ""),
                "host": .string("mail.example.com"),
                "priority": .integer(10),
            ])
        }
    }
    var context = LassoContext(emailProvider: EmailProvider())

    let output = try await LassoRenderer().render(
        "[email_mxlookup('example.com')->find('host')]",
        context: &context
    )
    #expect(output == "mail.example.com")
}

// MARK: - Cheap non-blocking fix B (Phase E milestone review): `email_result`/
// `email_status` LassoParser-level dispatch tests, mirroring `email_send`/
// `email_compose`/`email_mxlookup`'s existing pairs above.

@Test func emailResultThrowsEmailNotConfiguredWhenNoEmailProviderIsWired() async throws {
    var context = LassoContext()
    await #expect(throws: LassoRuntimeError.emailNotConfigured) {
        try await LassoRenderer().render(
            "[email_result()]",
            context: &context
        )
    }
}

@Test func emailStatusThrowsEmailNotConfiguredWhenNoEmailProviderIsWired() async throws {
    var context = LassoContext()
    await #expect(throws: LassoRuntimeError.emailNotConfigured) {
        try await LassoRenderer().render(
            "[email_status('some-id')]",
            context: &context
        )
    }
}

@Test func emailResultDispatchesToTheConfiguredEmailProviderAndReturnsItsResult() async throws {
    struct EmailProvider: LassoEmailProvider {
        func send(_ arguments: [EvaluatedArgument], context: LassoContext) async throws -> LassoEmailSendResult { LassoEmailSendResult(value: .void, jobID: nil) }
        func compose(_ arguments: [EvaluatedArgument], context: LassoContext) async throws -> LassoValue { .void }
        func mxLookup(_ arguments: [EvaluatedArgument], context: LassoContext) async throws -> LassoValue { .void }
        func result(context: LassoContext) async throws -> LassoValue { .string("test-job-id") }
    }
    var context = LassoContext(emailProvider: EmailProvider())

    let output = try await LassoRenderer().render(
        "[email_result()]",
        context: &context
    )
    #expect(output == "test-job-id")
}

@Test func emailStatusDispatchesToTheConfiguredEmailProviderAndReturnsItsResult() async throws {
    struct EmailProvider: LassoEmailProvider {
        func send(_ arguments: [EvaluatedArgument], context: LassoContext) async throws -> LassoEmailSendResult { LassoEmailSendResult(value: .void, jobID: nil) }
        func compose(_ arguments: [EvaluatedArgument], context: LassoContext) async throws -> LassoValue { .void }
        func mxLookup(_ arguments: [EvaluatedArgument], context: LassoContext) async throws -> LassoValue { .void }
        func status(_ arguments: [EvaluatedArgument], context: LassoContext) async throws -> LassoValue {
            .string("sent")
        }
    }
    var context = LassoContext(emailProvider: EmailProvider())

    let output = try await LassoRenderer().render(
        "[email_status('test-job-id')]",
        context: &context
    )
    #expect(output == "sent")
}

@Test func emailComposeMutatingBuilderMethodsThrowTheDedicatedRuntimeErrorNotNull() async throws {
    // Real corpus's own worked example chains `->addAttachment` right
    // after construction. Phase C's approved scope defers real mutation
    // (§4.3b/§4.8 point 2) but must not silently return `.null` for an
    // unregistered method name -- `NativeTypes.swift`'s
    // `makeEmailComposeType()` explicitly registers these four names so
    // each throws `LassoRuntimeError.emailComposeMutationNotYetSupported`
    // instead.
    struct EmailProvider: LassoEmailProvider {
        func send(_ arguments: [EvaluatedArgument], context: LassoContext) async throws -> LassoEmailSendResult { LassoEmailSendResult(value: .void, jobID: nil) }
        func compose(_ arguments: [EvaluatedArgument], context: LassoContext) async throws -> LassoValue {
            .object(LassoObjectInstance(typeName: "email_compose", data: [
                "_data": .string("data"), "_from": .string("b@example.com"), "_recipients": .array([]),
            ]))
        }
        func mxLookup(_ arguments: [EvaluatedArgument], context: LassoContext) async throws -> LassoValue { .void }
    }
    var context = LassoContext(emailProvider: EmailProvider())

    for method in ["addAttachment", "addHTMLPart", "addTextPart", "addPart"] {
        await #expect(throws: LassoRuntimeError.emailComposeMutationNotYetSupported(method)) {
            try await LassoRenderer().render(
                "[var(message = email_compose(-to='a', -from='b@example.com', -subject='s', -body='b'))][$message->\(method)()]",
                context: &context
            )
        }
    }
}

@Test func emailTokenRendersLiterallyAsTheHashWrappedMarker() async throws {
    // Phase F (§4.9c): `email_token(name)` is a pure, synchronous,
    // zero-I/O free function -- no `LassoEmailProvider` needed at all
    // (unlike `email_send`/`email_compose`/`email_mxlookup`, which all
    // throw `LassoRuntimeError.emailNotConfigured` with no provider
    // wired) -- confirmed here by rendering with a bare, provider-less
    // `LassoContext`. `LassoSMTPMessageBuilder`'s own `-tokens`/`-merge`
    // substitution pass is what later replaces this literal marker text
    // per recipient; this test only proves the marker itself renders
    // correctly, matching real Lasso's documented "the #TOKEN# marker can
    // be used instead" plain-text convention.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        "[email_token('FirstName')]",
        context: &context
    )
    #expect(output == "#FirstName#")
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

@Test func colonCallArgumentWithAParenthesizedChainedMemberCallParsesCorrectly() async throws {
    // Regression test for a real, pre-existing bug found while writing
    // Collections Stage 7c tests: a colon-call argument that is itself
    // a parenthesized base with a chained member call —
    // `('abe')->SubString(1,1)` — threw `unsupportedExpression(")")`
    // whether it was a non-last argument (followed by a comma and
    // another argument) or the last argument inside an explicit
    // `(Tag: ...)` wrap. Fixed as part of the broader `ArrowGiveback`
    // redesign (`ExpressionParser.swift`) — see its own doc comment,
    // and `colonCallArgumentWithABareChainedMemberCallParsesCorrectly`
    // below for the sibling case (a BARE, unparenthesized base) this
    // fix was initially narrower than, now also fixed.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        "[(Compare_LessThan: ('abe')->SubString(1,1), 'bob')]|[(Compare_LessThan: 'bob', ('abe')->SubString(1,1))]",
        context: &context
    )
    #expect(output == "0|-1")
}

@Test func colonCallArgumentWithABareChainedMemberCallParsesCorrectly() async throws {
    // Sibling to the parenthesized-base test above, for a BARE
    // (unparenthesized) base — `$x->SubString(1,1)` as a colon-call
    // argument. Previously: as a non-last argument (followed by a
    // comma and another argument), this threw
    // `unsupportedExpression(")")`; as the sole/last argument, it
    // silently MIS-parsed as `(Compare_LessThan: $x)->SubString(1,1)`
    // instead of the intended `Compare_LessThan($x->SubString(1,1))`.
    // Fixed by the `ArrowGiveback` redesign: every argument's `->`
    // chain is now parsed greedily (no suppression), then GIVEN BACK
    // to the enclosing call only when genuinely ambiguous — neither a
    // comma nor a `)` follows (see `ExpressionParser.swift`'s own doc
    // comment on `ArrowGiveback` for the full reasoning). A comma or a
    // `)` following the chain proves it unambiguously belongs to the
    // argument, exactly as it does for the already-fixed parenthesized
    // case.
    //
    // `$x`/`'zap'` are chosen deliberately (found by architect review
    // to matter): the FULL string and the SUBSTRING must compare
    // DIFFERENTLY against the other operand, or a version of this test
    // that silently used `$x` instead of `$x->SubString(1,1)` would
    // pass "by luck" — `'zoo' < 'zap'` is FALSE (`'o' > 'a'` at the
    // second character) while `'z' < 'zap'` is TRUE (`'z'` is a strict
    // prefix of `'zap'`), so the two forms are only both correct if the
    // substring genuinely got applied.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        """
        [var('x' = 'zoo')]
        [(Compare_LessThan: $x->SubString(1,1), 'zap')]|\
        [(Compare_LessThan: 'zap', $x->SubString(1,1))]
        """,
        context: &context
    ).trimmingCharacters(in: .whitespacesAndNewlines)
    #expect(output == "0|-1")
}

@Test func bareColonCallStillCorrectlyBindsATrailingArrowToTheCallResultWhenGenuinelyAmbiguous() async throws {
    // Companion to `bareColonCallArgumentDoesNotAbsorbATrailingArrowMember
    // Access` above (the original motivating case for this whole
    // mechanism) — confirms the `ArrowGiveback` redesign didn't regress
    // it, using the exact same proof technique: with NOTHING safe (no
    // comma, no `)`) following a bare argument's own trailing `->`
    // chain, that chain must still bind to the CALL's result, not the
    // argument. `MakeArray` wraps its argument in a 1-element array —
    // if `->first` incorrectly bound to the bare `5` argument itself
    // (`MakeArray(5->first)`), it would throw
    // `unsupportedExpression("Member first")` (integers have no
    // `first` member, same crash the original motivating test's own
    // bug produced); binding correctly to the call's result
    // (`MakeArray(5)->first`, i.e. `array(5)->first`) evaluates cleanly
    // to `5`.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        """
        [
        Define_Tag('MakeArray', -Required='Value');
            Return(Array((Local: 'Value')));
        /Define_Tag;
        ]\
        [MakeArray:5->first]
        """,
        context: &context
    ).trimmingCharacters(in: .whitespacesAndNewlines)
    #expect(output == "5")
}

@Test func bareColonCallArgumentWithATrailingChainInACompoundExpressionIsNotCorrupted() async throws {
    // Safety-guard test: `ArrowGiveback` must NEVER apply when the
    // argument's own top-level shape is a compound expression
    // (`.binary`/`.ternary`/etc.) wrapping a trailing chain, since
    // giving back just the chain would silently discard the rest of
    // the expression. `1 + $arr->first` as a bare colon-call's sole
    // argument must keep its `+` intact regardless of what
    // (non-)ambiguity the trailing `->first` might otherwise have.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        """
        [
        Define_Tag('Describe', -Required='Value');
            Return('got:' + (Local: 'Value'));
        /Define_Tag;
        var('arr' = array('first-element', 'unused'));
        ]\
        [Describe:1 + $arr->first]
        """,
        context: &context
    ).trimmingCharacters(in: .whitespacesAndNewlines)
    #expect(output == "got:1first-element")
}

@Test func nestedBareColonCallUnderAnExplicitParenWrapStillResolvesItsOwnAmbiguityCorrectly() async throws {
    // Regression test for a real bug found by architect review during
    // the `ArrowGiveback` redesign: `(Outer: $arr->get:2->first)` — a
    // BARE colon-call (`get:2`) nested, with no wrap of its own, inside
    // ANOTHER bare colon-call (`Outer:`) that IS explicitly wrapped in
    // parens. `get`'s own giveback check must NOT treat the upcoming
    // `)` as a safe terminator for ITS OWN ambiguity — that `)` belongs
    // to `Outer`'s wrap, two levels up, not to `get`'s own (nonexistent)
    // wrap. Before the fix, `get`'s own check saw ANY upcoming `)` as
    // universally safe, incorrectly leaving `2->first` bound together as
    // `get`'s own argument (`get(2->first)`) — which crashes at
    // evaluation (integers have no `first` member) instead of correctly
    // resolving to `($arr->get:2)->first`, embedded as `Outer`'s single
    // argument. Fixed via `enclosingCallArgumentListDepth` — an upcoming
    // `)` is only trusted when THIS bare call is the outermost one
    // currently active, not nested inside another still-open call frame.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        """
        [
        Define_Tag('Identity', -Required='Value');
            Return((Local: 'Value'));
        /Define_Tag;
        var(items::array = array);
        $items->insert('a' = array(1, 2, 3));
        $items->insert('b' = array(4, 5, 6));
        ]\
        [(Identity: $items->get:1->first)]
        """,
        context: &context
    ).trimmingCharacters(in: .whitespacesAndNewlines)
    #expect(output == "a")
}

@Test func giveBackDoesNotLeakPastAnEmbeddedCallWithinTheSameChain() async throws {
    // Regression test for a real bug found by code review during the
    // `ArrowGiveback` redesign: a chain containing an embedded bare
    // colon-call (`->get:1`) followed by FURTHER `->` chaining
    // (`->first`) — e.g. `$items->get:1->first`, the exact shape the
    // ORIGINAL motivating fix targeted — used as ANOTHER bare colon-
    // call's sole/trailing argument. The `giveback` captured at the
    // FIRST eligible `->` step (before `->get`) must NOT survive past
    // the embedded `:`-triggered call that follows it — that call
    // already resolved its OWN internal ambiguity independently,
    // producing a new, self-contained value; the earlier, now-stale
    // giveback point would otherwise cause the OUTER call to rewind too
    // far back, discarding `->get:1->first` entirely and re-attaching
    // it to the OUTER call's own result instead.
    //
    // **`MakeArray` must be a genuinely TRANSFORMING tag, not a
    // passthrough.** Two earlier versions of this test were found
    // non-decisive on review: (1) wrapping `MakeArray:...` directly in
    // parens (`(MakeArray:...)->join(',')`) made `MakeArray:`'s own
    // giveback check see itself as the OUTERMOST bare call, independently
    // masking the bug via the depth-tracking fix's own guard; (2) nesting
    // it unwrapped under another bare call (`Outer: Inner:...`) fixed
    // that, but using a no-op passthrough `Inner` meant the corrupted and
    // correct parse trees evaluate to the SAME final value regardless of
    // which one runs — a stale giveback causes `Inner`'s whole
    // `->get:1->first` chain to get re-parsed OUTSIDE `Inner`'s call
    // instead of resolved inside it (`Inner($items)->get:1->first` vs.
    // `Inner($items->get:1->first)`), and since `Inner(x) == x`, member
    // access commutes straight through either way, producing `10` either
    // way — found by architect re-verification: this version would have
    // passed even with the fix fully reverted. `MakeArray` genuinely
    // transforms (wraps its argument in a 1-element array), so the two
    // parse trees evaluate to visibly different results (`"10,20,30"` if
    // broken vs. `"10"` if correct) — architect-verified decisive by
    // reverting the fix and confirming the output actually changes.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        """
        [
        Define_Tag('Outer', -Required='Value');
            Return((Local: 'Value'));
        /Define_Tag;
        Define_Tag('MakeArray', -Required='Value');
            Return(Array((Local: 'Value')));
        /Define_Tag;
        var('items' = array(array(10, 20, 30)));
        ]\
        [(Outer: MakeArray:$items->get:1->first)->join(',')]
        """,
        context: &context
    ).trimmingCharacters(in: .whitespacesAndNewlines)
    #expect(output == "10")
}

@Test func bareColonCallNestedInsideAWrappedCallArgumentStillResolvesItsOwnAmbiguityCorrectly() async throws {
    // Regression test for a real bug found by architect re-verification:
    // the depth counter guarding the giveback boundary check originally
    // only tracked BARE (`closing == nil`) `parseArguments` calls, so a
    // bare colon-call nested directly inside an ordinary WRAPPED call's
    // argument — `Identity($items->get:1->first)`, where `Identity(...)`
    // uses regular parens as ITS OWN call syntax, not a bare colon-call —
    // never had that wrap counted. `get:`'s own frame incorrectly saw
    // itself as depth 0 (outermost) and wrongly trusted `Identity`'s own
    // closing `)` as a safe terminator for its own ambiguity, leaving
    // `1->first` bound together as `get`'s own argument (`get(1->first)`)
    // — which crashes at evaluation (integers have no `first` member) —
    // instead of correctly resolving to `($items->get:1)->first` as
    // `Identity`'s single argument. Fixed by having
    // `enclosingCallArgumentListDepth` count EVERY `parseArguments` call,
    // wrapped or bare, not just bare ones.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        """
        [
        Define_Tag('Identity', -Required='Value');
            Return((Local: 'Value'));
        /Define_Tag;
        var('items' = array(array(10, 20, 30)));
        ]\
        [Identity($items->get:1->first)]
        """,
        context: &context
    ).trimmingCharacters(in: .whitespacesAndNewlines)
    #expect(output == "10")
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
        capabilities: { _, _ in .readOnly },
        queryHandler: { _, _, _ in
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

@Test func returnInsideALoopBlockStopsIterationImmediatelyInsteadOfRunningToCompletion() async throws {
    // Real pre-existing bug, unrelated to Captures: the "loop" case in
    // `RendererEngine.renderBlock` only checked `consumeLoopControlSignal()`
    // (the `Loop_Abort`/`Loop_Continue` mechanism) after each iteration's
    // `render(body)` call, never `shouldStopRenderingCurrentBody()` (which
    // is what actually goes true for a `return`/`yield`). `render(_:)`'s own
    // per-node check only polls the flag AFTER a node runs, not before — so
    // with no equivalent check in the "loop" case's own Swift `for` loop,
    // iterations 4 and 5 still ran, and their `insert` call (the very FIRST
    // node of each iteration's body, so nothing skips it) executed anyway.
    // Must be a single line with no text/whitespace node between `[loop(5)]`
    // and the `insert` call — an incidental leading text node would itself
    // absorb the stale-signal check and mask the bug, making this
    // non-decisive (caught by reverting the fix and confirming failure).
    var context = LassoContext()
    _ = try await LassoRenderer().render(
        "[var(collected=array)][loop(5)][$collected->insert(loop_count)][if(loop_count==3)][return('done')][/if][/loop]",
        context: &context
    )
    #expect(context.value(for: "collected", scope: .global) == .array([.integer(1), .integer(2), .integer(3)]))
}

@Test func returnInsideAnIterateBlockStopsIterationImmediatelyInsteadOfRunningToCompletion() async throws {
    // Same bug shape as the `loop` case above, in `renderBlock`'s
    // "iterate" case: `consumeLoopControlSignal()` alone can't see a
    // `return`/`yield`'s `returnSignal`, so without also checking
    // `shouldStopRenderingCurrentBody()`, `iterate` kept walking the rest
    // of the source array after the matching element instead of stopping.
    // Same single-line requirement as the `loop` test above, for the same
    // reason.
    var context = LassoContext()
    _ = try await LassoRenderer().render(
        "[var(collected=array)][iterate(array(10,20,30,40,50), var(x))][$collected->insert($x)][if($x==30)][return('done')][/if][/iterate]",
        context: &context
    )
    #expect(context.value(for: "collected", scope: .global) == .array([.integer(10), .integer(20), .integer(30)]))
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
    #expect(output == "ab|7|8|2.500000")
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
        capabilities: { _, _ in .readOnly },
        queryHandler: { _, _, _ in
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

@Test func relationalOperatorsCompareStringsAlphabeticallyNotByLength() async throws {
    // Regression test for a real, pre-existing bug: the raw `<`/`>`/
    // `<=`/`>=` operators' non-numeric fallback compared
    // `Double(outputString.count)` — i.e. STRING LENGTH — instead of
    // actual lexicographic content, so `'a' < 'b'` incorrectly returned
    // `false` (both length 1). Ch. 5 Table 11 (p.78) documents the real
    // contract directly: "check whether strings come before or after
    // each other in alphabetical order," with the Guide's own worked
    // example verbatim (`'abc' < 'def'` → True) — used as the first
    // assertion below. `'aa' < 'b'` and `'zz' > 'a'` specifically prove
    // this isn't accidentally still comparing by length (a longer
    // string sorting before/after a shorter one purely by alphabetical
    // content, contradicting what length-based comparison would give).
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        "[('abc' < 'def')]|[('aa' < 'b')]|[('zz' > 'a')]|[('abc' <= 'abc')]|[('abc' >= 'abc')]|[('b' > 'a')]",
        context: &context
    )
    #expect(output == "true|true|true|true|true|true")
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

@Test func typeReturnsCapitalizedTypeNameMatchingTheLanguageGuidesOwnWorkedExamples() async throws {
    // Lasso 8.5 Language Guide Ch. 43 Table 6 / p.560, exact worked
    // examples: `[123->Type] -> Integer`, `[Output: 123.456->Type] ->
    // Decimal`, `['String'->Type] -> String`, `[Null->Type] -> Null`,
    // `[(Array: 1, 2, 3)->Type] -> Array`.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        "[123->type]|[123.456->type]|['String'->type]|[Null->type]|[(Array(1,2,3))->type]",
        context: &context
    )
    #expect(output == "Integer|Decimal|String|Null|Array")
}

@Test func typeReturnsTheRegisteredNativeTypeNameUnmodifiedForObjectInstances() async throws {
    // lassoguide.com's Lasso 9 "Type/Object Introspection Methods":
    // "Returns the type name for any type instance. The value is the
    // name that was used when the type was defined" — native types are
    // registered lowercase (see NativeTypes.swift's `makeRegExpType`),
    // so unlike the primitive-literal capitalization above, this is
    // returned as-is, not capitalized.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        "[var(re = RegExp(-Find='a'))][$re->type]",
        context: &context
    )
    #expect(output.trimmingCharacters(in: .whitespacesAndNewlines) == "regexp")
}

@Test func isAMatchesTheValuesOwnTypeNameCaseInsensitivelyAndIsNotAIsItsOpposite() async throws {
    // Ch. 43 Table 6: "[Null->IsA] Requires a type name as a parameter.
    // Returns true if the object is of that type or inherits from that
    // type." This interpreter has no type-inheritance model (see the
    // doc comment on `member()`'s "isa"/"isnota" case), so only the
    // exact-type-name half is exercised here. `->IsNotA` per
    // lassoguide.com: "The opposite of null->isA."
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        "[('hello')->isA('string')]|[('hello')->isA('String')]|[(123)->isA('integer')]|[(123)->isA('string')]|[('hello')->isNotA('string')]|[('hello')->isNotA('integer')]",
        context: &context
    )
    #expect(output == "true|true|true|false|false|true")
}

@Test func hasMethodReportsTrueForRealMemberMethodsAndFalseForUnknownOnes() async throws {
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        "[('hello')->hasMethod('uppercase')]|[('hello')->hasMethod('notarealmethod')]|[(Array(1,2))->hasMethod('sort')]|[(Array(1,2))->hasMethod('notarealmethod')]",
        context: &context
    )
    #expect(output == "true|false|true|false")
}

@Test func typeIsAAndHasMethodAreThemselvesAlwaysReportedAvailable() async throws {
    // "the null data type is the base type for all other data types...
    // All of the tags of the null data type are available for use with
    // values of any data type" (Ch. 43, introducing Table 6) — so
    // ->HasMethod must report its own sibling introspection tags as
    // present on every type, not just the type-specific methods listed
    // in `Evaluator.primitiveMethodNames`.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        "[(123)->hasMethod('type')]|[(123)->hasMethod('isA')]|[(123)->hasMethod('isNotA')]|[(123)->hasMethod('hasMethod')]",
        context: &context
    )
    #expect(output == "true|true|true|true")
}

@Test func hasMethodTypeAndIsAWorkOnACustomUserDefinedType() async throws {
    // Scrubbed down from the same js_timer.inc shape used by
    // `legacyDefineTypeColonCallRegistersTypeAndMethods` above.
    // `->HasMethod` for `.object` instances consults the user-defined
    // type's own registered methods (not the hand-maintained primitive
    // table), and `->Type` returns the name exactly as it was passed to
    // `Define_Type` (case preserved, not capitalized like the
    // primitive-literal worked examples above).
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        """
        [
        define_type: 'Ex_Timer', 'integer', -prototype;
            local: 'ticks'=0;
            define_tag: 'bump';
                (self->'ticks') = (self->'ticks') + 1;
            /define_tag;
        /define_type;
        ]
        [Local(t = Ex_Timer())][#t->type]|[#t->isA('Ex_Timer')]|[#t->hasMethod('bump')]|[#t->hasMethod('notarealmethod')]
        """,
        context: &context
    ).trimmingCharacters(in: .whitespacesAndNewlines)

    #expect(output == "Ex_Timer|true|true|false")
}

@Test func typeIsAAndHasMethodReachTheOuterDefaultFallbackForBooleanAndPair() async throws {
    // `.boolean` and `.pair` have no dedicated case anywhere in
    // `member()`'s own switch, so these three tags are ONLY reachable
    // for them via the outer switch's final `default:` fallback —
    // locking that path in directly (architect review flagged it as
    // otherwise unverified by any test) rather than relying on it being
    // exercised incidentally by the primitive-literal tests above.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        "[(true)->type]|[(true)->isA('boolean')]|[(true)->hasMethod('type')]|[(Pair(1,2))->type]|[(Pair(1,2))->isA('pair')]",
        context: &context
    )
    #expect(output == "Boolean|true|true|Pair|true")
}

@Test func typeWorksOnAMapWithNoKeyCollidingWithTheTagName() async throws {
    // The other `.map` coverage above (`hasMethodReportsTrueForRealMemberMethodsAndFalseForUnknownOnes`
    // and the pre-existing `fileUploadsExposeMetadataUnderBothLasso9And8KeyNames`)
    // only exercises the key-collision side of `.map`'s key-first
    // priority. This locks in the OTHER side: a map with no `"type"`
    // key must still reach `introspectionResult`'s fallback rather than
    // falling all the way through to the unconditional `.null` the
    // `.map` case returns for any other genuinely unknown member.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        "[(Map('a'=1))->type]|[(Map('a'=1))->hasMethod('type')]",
        context: &context
    )
    #expect(output == "Map|true")
}

@Test func voidTypeDegradesGracefullyLikeItsOtherMemberAccessesInsteadOfThrowing() async throws {
    // Regression-locks a deliberate, disclosed extension of the
    // existing void-degrades-to-empty-string convention (see the
    // `(.void, _)` case's own doc comment) rather than leaving it as an
    // unexamined side effect of adding these tags, per architect
    // review. `action_param('missing')` is the same real-corpus
    // lookup-miss source `voidLookupMissBehavesLikeEmptyStringButNullStaysStrict`
    // already uses above.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        "[action_param('missing')->type]|[action_param('missing')->hasMethod('uppercase')]",
        context: &context
    )
    #expect(output == "String|true")
}

@Test func varResetAndLocalResetSetAVariableMatchingTheLanguageGuidesOwnWorkedExample() async throws {
    // Lasso 8.5 Language Guide Ch. 15 p.226, exact worked example:
    // `Var_Reset: 'VariableName'='New Value'; $VariableName;` -> "New
    // Value". This codebase has no `@`/`[Reference]` variable-aliasing
    // system (deferred — see `Evaluator.declarationScope(for:)`'s own
    // doc comment), so "detaching any references" has nothing to do;
    // `Var_Reset`/`Local_Reset` are implemented as plain synonyms for
    // `Var`/`Local`, verified here to at least match the documented
    // set-and-read behavior.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        "[Var_Reset: 'VariableName'='New Value'][$VariableName][Local('l' = 1)][Local_Reset('l' = 2)][#l]",
        context: &context
    )
    #expect(output == "New Value2")
}

@Test func globalSetAndGetMatchesTheLanguageGuidesOwnWorkedExample() async throws {
    // Ch. 15 p.227, exact worked example:
    // `[Global: 'Administrator_Email' = 'administrator@example.com']`
    // then `[Global: 'Administrator_Email']` ->
    // "administrator@example.com".
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        "[Global: 'Administrator_Email' = 'administrator@example.com'][Global: 'Administrator_Email']",
        context: &context
    )
    #expect(output == "administrator@example.com")
}

@Test func dollarSymbolFallsBackToAGlobalOnlyWhenNoPageVariableOfTheSameNameExists() async throws {
    // Ch. 15 p.227: "The $ symbol will return a global variable if no
    // page variable of the same name has been created." Also verifies
    // the two namespaces stay genuinely separate (a page `Variable` and
    // a true `Global` sharing a name are different variables, matching
    // real Lasso) rather than colliding in shared storage.
    var context = LassoContext()
    let fallbackOutput = try await LassoRenderer().render(
        "[Global: 'g_only' = 'from global'][$g_only]",
        context: &context
    )
    #expect(fallbackOutput == "from global")

    var shadowedContext = LassoContext()
    let shadowedOutput = try await LassoRenderer().render(
        "[Global: 'shared' = 'global value'][Variable: 'shared' = 'page value'][$shared]|[Global: 'shared']",
        context: &shadowedContext
    )
    #expect(shadowedOutput == "page value|global value")
}

@Test func globalResetGlobalDefinedGlobalRemoveAndGlobalsMap() async throws {
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        """
        [Global_Reset: 'g' = 1]
        [Global_Defined: 'g']|[Global_Defined: 'never_set']
        [Global: 'g2' = 2]
        [(Globals)->size]
        [Global_Remove: 'g']
        [Global_Defined: 'g']|[(Globals)->size]
        """,
        context: &context
    )
    let lines = output
        .split(separator: "\n")
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
    #expect(lines == ["true|false", "2", "false|1"])
}

@Test func varDefinedStaysScopedToThePageAndIsNotFooledByAnUnrelatedTrueGlobal() async throws {
    // Ch. 15 p.225: "The [Variable_Defined] tag can be used to check if
    // a variable has been created and used in THE CURRENT LASSO PAGE."
    // Regression test for a real bug caught by architect review: an
    // earlier version of the `$name`-falls-back-to-a-global fix
    // (`LassoContext.value(for:scope:)`'s `.global` case, see its own
    // doc comment) mistakenly also placed the fallback on `.unscoped`
    // — which `var_defined`'s free-function registration reads through
    // — making `Var_Defined('x')` silently report `true` whenever an
    // unrelated true Global named "x" existed, even with no page
    // variable ever created.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        "[Global: 'onlyglobal' = 'g'][Var_Defined: 'onlyglobal']",
        context: &context
    )
    #expect(output == "false")
}

@Test func nullSuppressesOutputWhileStillEvaluatingItsArgument() async throws {
    // Ch. 30 pp.422-426's canonical Iterator idiom relies on exactly
    // this: `Null: $myIterator->Forward;` must silently swallow the
    // boolean return value while still actually advancing the iterator.
    // Previously "null" always hard-committed to the `.null` literal
    // expression in `parsePrefix` before `parsePostfix` ever saw a
    // trailing `(` or `:`, so both call syntaxes below threw
    // `unsupportedExpression("Dynamic call")` — a `.call` node whose
    // callee was `.null` instead of `.identifier("null")`, which
    // `Evaluator.evaluate`'s `.call` case has no path for.
    //
    // Proven here via a divide-by-zero inside the argument (caught by
    // `[protect]`): if the argument were silently discarded rather than
    // actually evaluated, no error would ever surface.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        "[null(1+1)]|[protect][Null: 10 / 0][/protect][error_currenterror(-errorcode)]",
        context: &context
    )
    #expect(output == "|-9950")
}

@Test func bareNullStillParsesAsTheLiteralNullValueNotACall() async throws {
    // Guards the other half of the fix: "null" with no following call
    // syntax must keep parsing as the `.null` literal, so ordinary
    // comparisons against it are unaffected by the new callable path.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        "[Var: 'x' = null][$x == null]|[null == null]",
        context: &context
    )
    #expect(output == "true|true")
}

@Test func listFirstAndLastMatchTheLanguageGuidesWorkedExample() async throws {
    // Ch. 30 p.399: `Var('MyList' = (List: 'Uno', 'Dos', 'Tres',
    // 'Quatro'))` then `$myList->First + ', ' + $myList->Last` → "Uno,
    // Quatro". Also covers `->Size` → 4 from the same page.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        """
        [var('myList' = (list: 'Uno', 'Dos', 'Tres', 'Quatro'))]\
        [$myList->First] + [$myList->Last]|[$myList->Size]
        """,
        context: &context
    )
    #expect(output == "Uno + Quatro|4")
}

@Test func listInsertFirstInsertLastThenAutoStringMatchesTheGuidesSixElementResult() async throws {
    // Ch. 30 p.399: `->InsertFirst('Cero')` + `->InsertLast('Cinco')`
    // on the same list, then `[String: $myList]` → "List: Cero, Uno,
    // Dos, Tres, Quatro, Cinco" — a bare-statement self-mutating
    // write-back, no reassignment.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        """
        [var('myList' = (list: 'Uno', 'Dos', 'Tres', 'Quatro'))]\
        [$myList->InsertFirst('Cero')][$myList->InsertLast('Cinco')]\
        [string($myList)]
        """,
        context: &context
    )
    #expect(output == "List: Cero, Uno, Dos, Tres, Quatro, Cinco")
}

@Test func listRemoveFirstAndRemoveLastReturnToTheOriginalFourElements() async throws {
    // Ch. 30 p.399: continuing from the six-element list above,
    // `->RemoveFirst` + `->RemoveLast` → "List: Uno, Dos, Tres, Quatro".
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        """
        [var('myList' = (list: 'Cero', 'Uno', 'Dos', 'Tres', 'Quatro', 'Cinco'))]\
        [$myList->RemoveFirst][$myList->RemoveLast]\
        [string($myList)]
        """,
        context: &context
    )
    #expect(output == "List: Uno, Dos, Tres, Quatro")
}

@Test func listDifferenceIntersectionAndUnionSelfMutateOnABareStatementLikeSetDoes() async throws {
    // Extrapolation test, NOT a primary-source-verified worked example
    // — unlike Set, the Guide has no dedicated List->Difference/
    // ->Intersection/->Union worked example to confirm bare-statement
    // behavior against. This is included in `Evaluator
    // .selfMutatingMethods` on the (disclosed, name-based-not-type-
    // scoped) theory that List's own Table 5 wording ("returning a new
    // list"/"Returns a new list") is JUST as inconsistent with actual
    // bare-statement-mutates behavior as Set's identically-worded Table
    // 16 turned out to be (verified by Set's own worked example, see
    // `setDifferenceIntersectionAndUnionMatchTheGuidesFirstSetSecondSetWorkedExamples`
    // above) — flagged explicitly by architect review as an
    // unverified-for-List extrapolation, kept as the most consistent
    // reading available, and captured here as a regression test of the
    // actual implemented behavior rather than left silently untested.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        """
        [var('FirstList' = (list: 'Alpha', 'Beta', 'Gamma'))]\
        [var('SecondList' = (list: 'Beta', 'Gamma', 'Delta'))]\
        [var('ResultList' = $FirstList)][$ResultList->Difference($SecondList)][$ResultList->Size]|\
        [var('ResultList' = $FirstList)][$ResultList->Intersection($SecondList)][$ResultList->Size]|\
        [var('ResultList' = $FirstList)][$ResultList->Union($SecondList)][$ResultList->Size]
        """,
        context: &context
    )
    #expect(output == "1|2|4")
}

@Test func listConstructorWithNoArgumentsIsEmptyAndBareIdentifierResolvesToAnEmptyList() async throws {
    // `List` constructor "Any parameters passed to the tag are used as
    // the initial values" (Table 4) implies zero parameters is a valid
    // empty list. Also confirms the real-corpus bare-identifier path
    // (`var('x' = list)`, mirroring `includes/detail_a_sku.lasso`'s
    // `var('skuArrayColor' = set)`) resolves to an empty instance with
    // no separate free-function registration needed for that shape.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        "[(list)->size]|[var('x' = list)][$x->size]",
        context: &context
    )
    #expect(output == "0|0")
}

@Test func queueFirstSizeAndAutoStringMatchTheLanguageGuidesWorkedExamples() async throws {
    // Ch. 30 pp.408-409: Insert('One'), Insert('Two') then `->First` →
    // "One" (FIFO peek, no mutation), `->Size` → 2, `[String: $myQueue]`
    // → "Queue: One, Two".
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        """
        [var('myQueue' = queue)][$myQueue->Insert('One')][$myQueue->Insert('Two')]\
        [$myQueue->First]|[$myQueue->Size]|[string($myQueue)]
        """,
        context: &context
    )
    #expect(output == "One|2|Queue: One, Two")
}

@Test func queueAndStackConstructorsAcceptInitialElementsLikeListDoes() async throws {
    // The 8.5 PDF's own Table 12/17 say "Creates an empty queue"/
    // "Creates an empty stack" with no constructor parameters
    // documented at all, but lassoguide.com's Lasso 9 docs explicitly
    // say "Creates a queue/stack object using the parameters passed to
    // it as the elements" (cross-checked directly against
    // lassoguide.com/operations/collections.html, flagged as a real gap
    // by architect review, not left as the PDF's narrower "always
    // empty" reading). Argument order becomes insertion order, so
    // Queue's FIFO `->First` is the first argument and Stack's LIFO
    // `->First` is the last argument.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        "[(queue: 'One', 'Two')->First]|[(stack: 'One', 'Two')->First]",
        context: &context
    )
    #expect(output == "One|Two")
}

@Test func queueGetPopsAndDisplaysTheFirstElementMatchingTheGuidesOneThenOneResult() async throws {
    // Ch. 30 p.409: the exact worked example this project's disclosed
    // `->Get` exception exists for — a bare `$myQueue->Get;` statement
    // both DISPLAYS "One" and MUTATES the queue (confirmed by `->Size`
    // afterward reporting 1, not 2).
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        """
        [var('myQueue' = queue)][$myQueue->Insert('One')][$myQueue->Insert('Two')]\
        [$myQueue->Get]|[$myQueue->Size]
        """,
        context: &context
    )
    #expect(output == "One|1")
}

@Test func queueRemoveDiscardsTheFirstElementWithoutReturningItsValue() async throws {
    // Ch. 30 p.409: `[Queue->Remove]` "does not return any value so
    // only the size is output" — 1, after removing one of two elements.
    // Also confirms it's FIFO removal specifically (not just "any
    // element"): `->First` afterward is the surviving 'Two', not 'One'
    // — code review flagged the original version of this test as
    // unable to distinguish `removeFirst` from `removeLast` since
    // either leaves size 1 on a 2-element queue.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        """
        [var('myQueue' = queue)][$myQueue->Insert('One')][$myQueue->Insert('Two')]\
        [$myQueue->Remove][$myQueue->First]|[$myQueue->Size]
        """,
        context: &context
    )
    #expect(output == "Two|1")
}

@Test func stackFirstSizeAndAutoStringMatchTheLanguageGuidesWorkedExamplesLIFOOrder() async throws {
    // Ch. 30 pp.413-414: Insert('One'), Insert('Two') then `->First` →
    // "Two" (LIFO peek — the most recently inserted, unlike Queue's
    // FIFO "One"), `->Size` → 2, `[String: $myStack]` → "Stack: One,
    // Two" (still insertion order for the auto-string dump, per the
    // Guide's own worked example — NOT peek order).
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        """
        [var('myStack' = stack)][$myStack->Insert('One')][$myStack->Insert('Two')]\
        [$myStack->First]|[$myStack->Size]|[string($myStack)]
        """,
        context: &context
    )
    #expect(output == "Two|2|Stack: One, Two")
}

@Test func stackGetPopsAndDisplaysTheMostRecentlyInsertedElementMatchingTheGuidesTwoThenOneResult() async throws {
    // Ch. 30 p.415: same disclosed `->Get` exception as Queue, but LIFO
    // — pops "Two" (not "One"), leaving size 1.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        """
        [var('myStack' = stack)][$myStack->Insert('One')][$myStack->Insert('Two')]\
        [$myStack->Get]|[$myStack->Size]
        """,
        context: &context
    )
    #expect(output == "Two|1")
}

@Test func stackRemoveDiscardsTheMostRecentlyInsertedElementSpecificallyNotJustAnyElement() async throws {
    // Same order-verification gap code review flagged for Queue->Remove
    // above, mirrored for Stack: `->Remove` is LIFO (removes 'Two', not
    // 'One'), confirmed via `->First` on the survivor afterward rather
    // than size alone.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        """
        [var('myStack' = stack)][$myStack->Insert('One')][$myStack->Insert('Two')]\
        [$myStack->Remove][$myStack->First]|[$myStack->Size]
        """,
        context: &context
    )
    #expect(output == "One|1")
}

@Test func listContainsMatchesAnElementByValueEqualityNotReferenceIdentity() async throws {
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        "[(list: 'Uno', 'Dos', 'Tres')->Contains('Dos')]|[(list: 'Uno', 'Dos', 'Tres')->Contains('Cero')]",
        context: &context
    )
    #expect(output == "true|false")
}

@Test func setFindReturnsANewSetOfMatchesNotAnArrayUnlikeListFind() async throws {
    // Table 16: "[Set->Find] Returns a SET of elements that match" —
    // deliberately distinct from List->Find, which returns a plain
    // array (Table 5). Asserting the auto-string prefix is "Set:" (not
    // bare/array-shaped output) is what actually distinguishes this
    // from a copy-pasted List->Find implementation, which is exactly
    // the regression code review flagged this as having zero coverage
    // against.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        """
        [var('mySet' = set)][$mySet->Insert('Alpha')][$mySet->Insert('Beta')][$mySet->Insert('Gamma')]\
        [string($mySet->Find('Beta'))]
        """,
        context: &context
    )
    #expect(output == "Set: (Beta)")
}

@Test func setContainsGetAndRemoveAllMatchTheirOwnTableDescriptions() async throws {
    // Table 16: `->Contains` (boolean membership test), `->Get` (1-
    // based positional getter — sets are always sorted, so position 1
    // of {Alpha,Beta,Gamma} is 'Alpha'), `->RemoveAll` (VALUE-based,
    // unlike `->Remove`'s position-based removal — removes every
    // matching element, "Returns no value").
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        """
        [var('mySet' = set)][$mySet->Insert('Alpha')][$mySet->Insert('Beta')][$mySet->Insert('Gamma')]\
        [$mySet->Contains('Beta')]|[$mySet->Get(1)]|\
        [$mySet->RemoveAll('Beta')][$mySet->Size]|[string($mySet)]
        """,
        context: &context
    )
    #expect(output == "true|Alpha|2|Set: (Alpha), (Gamma)")
}

@Test func seriesConstructorProducesAnInclusiveAscendingArrayMatchingTheGuidesTenElementExample() async throws {
    // Ch. 30 p.413: `[Series(1, 10)]` produces 10 elements from 1 to 10
    // inclusive. Implemented as a plain `.array` (not object-wrapped)
    // per the same page's "supports the same member tags as the array
    // data type" — so this test exercises `->join` (an existing Array
    // member) rather than the Guide's own bare-cast "Series: (1),
    // (2)..." per-element-parens format, which is deliberately not
    // reproduced (see `LassoCollectionValue.autoStringDescription`'s
    // doc comment).
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        "[(series(1, 10))->size]|[(series(1, 10))->join(',')]",
        context: &context
    )
    #expect(output == "10|1,2,3,4,5,6,7,8,9,10")
}

@Test func setDeduplicatesRepeatedInsertsMatchingTheGuidesOneThreeWorkedExample() async throws {
    // Ch. 30 p.411: inserting 'Three' three times still yields only two
    // elements — "the multiple inserts of Three are ignored since the
    // set can only contain unique values" — dedup via `lassoEquals`,
    // no new Hashable infrastructure.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        """
        [var('mySet' = set)][$mySet->Insert('One')][$mySet->Insert('Three')]\
        [$mySet->Insert('Three')][$mySet->Insert('Three')]\
        [$mySet->Size]|[string($mySet)]
        """,
        context: &context
    )
    #expect(output == "2|Set: (One), (Three)")
}

@Test func setDifferenceIntersectionAndUnionMatchTheGuidesFirstSetSecondSetWorkedExamples() async throws {
    // Ch. 30 p.412: FirstSet={Alpha,Beta,Gamma}, SecondSet={Beta,Gamma,
    // Delta}. Each of Difference/Intersection/Union duplicates FirstSet
    // as ResultSet, calls the operation as a bare statement (no
    // reassignment), then displays $ResultSet — exercising the same
    // self-mutating write-back mechanism as everything else in this
    // set, now widened to cover these three method names too.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        """
        [var('FirstSet' = set)][$FirstSet->Insert('Alpha')][$FirstSet->Insert('Beta')][$FirstSet->Insert('Gamma')]\
        [var('SecondSet' = set)][$SecondSet->Insert('Beta')][$SecondSet->Insert('Gamma')][$SecondSet->Insert('Delta')]\
        [var('ResultSet' = $FirstSet)][$ResultSet->Difference($SecondSet)][$ResultSet]|\
        [var('ResultSet' = $FirstSet)][$ResultSet->Intersection($SecondSet)][$ResultSet]|\
        [var('ResultSet' = $FirstSet)][$ResultSet->Union($SecondSet)][$ResultSet]
        """,
        context: &context
    )
    #expect(output == "Set: (Alpha)|Set: (Beta), (Gamma)|Set: (Alpha), (Beta), (Delta), (Gamma)")
}

@Test func setConstructorWithNoArgumentsIsEmptyAndBareIdentifierResolvesToAnEmptySet() async throws {
    // Same bare-identifier confirmation as List above, but for `set` —
    // the exact real-corpus shape `includes/detail_a_sku.lasso` used
    // (`var('skuArrayColor' = set)`) that originally motivated this
    // whole file (the old placeholder `set(...)` registration didn't
    // dedup at all; see this file's own top-level doc comment).
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        "[(set)->size]|[var('x' = set)][$x->size]",
        context: &context
    )
    #expect(output == "0|0")
}

@Test func setConstructorWithPositionalArgumentsInsertsAndDedupsThemLikeListQueueStack() async throws {
    // lassoguide.com/operations/collections.html: "set(key, ...) — A
    // set is created with zero or more element parameters. The
    // element values are inserted into the set." Matches List/Queue/
    // Stack's own constructors, all of which insert their positional
    // arguments — `set(...)` previously silently dropped them (only
    // `set()`/bare `set` with zero elements worked). Repeated 'Three'
    // exercises the same dedup-on-insert behavior as `->Insert` itself
    // (see `setDeduplicatesRepeatedInsertsMatchingTheGuidesOneThreeWorkedExample`
    // above) — the constructor must dedup too, not just insert raw.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        "[string(set('One', 'Three', 'Three'))]|[(set(3, 4))->size]",
        context: &context
    )
    #expect(output == "Set: (One), (Three)|2")
}

@Test func priorityQueueDefaultComparatorReturnsTheGreatestElementFirst() async throws {
    // Ch. 30 p.405-406: default comparator (`\Compare_LessThan`) —
    // insert 'One' then 'Two', `->First` is "Two" (greatest
    // alphabetically), NOT "One" — the exact greatest-first-by-default
    // gotcha this stage's own risk assessment flagged as easy to invert
    // by assuming the comparator's own name is the sort direction.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        """
        [var('myPQ' = priorityqueue)][$myPQ->Insert('One')][$myPQ->Insert('Two')]\
        [$myPQ->First]|[$myPQ->Size]|[string($myPQ)]
        """,
        context: &context
    )
    #expect(output == "Two|2|PriorityQueue: One, Two")
}

@Test func priorityQueueGreaterThanComparatorReturnsTheLeastElementFirst() async throws {
    // Ch. 30 p.406: `(PriorityQueue: (Compare_GreaterThan))` reverses
    // the default — `->First` is "One" (least), not "Two".
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        """
        [var('myPQ' = (priorityqueue: (compare_greaterthan)))]\
        [$myPQ->Insert('One')][$myPQ->Insert('Two')][$myPQ->First]
        """,
        context: &context
    )
    #expect(output == "One")
}

@Test func backslashTagReferenceToABuiltInComparatorWorksIdenticallyToTheFreeTagForm() async throws {
    // Stage 6: real `\Compare_GreaterThan` bareword-reference syntax
    // (Table 21's own actual documented form) now supported — sibling
    // test to `priorityQueueGreaterThanComparatorReturnsTheLeastElementFirst`
    // above, which uses the `(compare_greaterthan)` free-tag stand-in
    // this codebase shipped in Stage 2 pending this exact parser work.
    // Same worked example, real syntax this time.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        """
        [var('myPQ' = (priorityqueue: \\Compare_GreaterThan))]\
        [$myPQ->Insert('One')][$myPQ->Insert('Two')][$myPQ->First]
        """,
        context: &context
    )
    #expect(output == "One")
}

@Test func backslashTagReferenceToAnUndefinedTagThrows() async throws {
    var context = LassoContext()
    await #expect(throws: LassoRuntimeError.unknownFunction("NoSuchTagAtAll")) {
        _ = try await LassoRenderer().render("[\\NoSuchTagAtAll]", context: &context)
    }
}

@Test func backslashTagReferenceToACustomDefinedTagIsValidButNotYetDispatchedAsAComparator() async throws {
    // A `\TagName` reference to a real, user-`Define_Tag`'d custom tag
    // must be accepted (it names something real) but, per this stage's
    // own disclosed scope limit (`TagReference.swift`'s doc comment),
    // does NOT yet dispatch as a real comparator when passed to
    // PriorityQueue's constructor — falls back to the exact same
    // "unrecognized comparator value" natural-order behavior any other
    // non-comparator argument already gets. Proves this degrades
    // gracefully (no crash, no silently-wrong-but-plausible ordering
    // claim) rather than being asserted only by doc comment.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        """
        [
        Define_Tag('MyComparator', -Required='Left', -Required='Right');
            Return(-1);
        /Define_Tag;
        var('myPQ' = (priorityqueue: \\MyComparator));
        $myPQ->Insert('Two');
        $myPQ->Insert('One');
        ]\
        [$myPQ->First]|[$myPQ->Size]
        """,
        context: &context
    )
    #expect(output == "Two|2")
}

@Test func backslashTagReferenceToACustomDefinedTypeIsValidNotJustCustomTags() async throws {
    // Regression test for a real bug architect review found: the
    // `.tagReference` existence guard originally checked
    // `context.natives.contains`/`context.tagRegistry.containsTag`/
    // `context.nativeTypes.containsType` — but `context.nativeTypes`
    // only covers BUILT-IN types; a genuinely `Define_Type`-defined
    // custom type lives in `context.tagRegistry`'s own separate `types`
    // dictionary (`containsType(named:)`), which the guard omitted
    // entirely. `\MyCustomType` on a real, defined custom type
    // incorrectly threw `unknownFunction` — worse than the disclosed
    // "valid reference, not yet dispatched" behavior `\MyCustomTag`
    // already gets above. This matters concretely, not just for
    // completeness: Ch. 30 p.420 documents custom comparators as
    // buildable "as custom tags or as custom types by overriding the
    // onCompare callback tag" — `\MyComparatorType` is a real,
    // documented shape. Must not throw.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        """
        [
        Define_Type('MyComparatorType');
        /Define_Type;
        var('ref' = \\MyComparatorType);
        ]OK
        """,
        context: &context
    )
    #expect(output == "OK")
}

@Test func priorityQueueGetPopsTheGreatestElementMatchingTheGuidesTwoThenOneResult() async throws {
    // Ch. 30 p.406-407: same disclosed atomic-`->Get` pattern as Queue/
    // Stack — pops "Two" (the current greatest), leaving size 1.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        """
        [var('myPQ' = priorityqueue)][$myPQ->Insert('One')][$myPQ->Insert('Two')]\
        [$myPQ->Get]|[$myPQ->Size]
        """,
        context: &context
    )
    #expect(output == "Two|1")
}

@Test func priorityQueueConstructorIgnoresPositionalArgumentsAndIsAlwaysCreatedEmpty() async throws {
    // Unlike `set(...)` (fixed above to insert its positional
    // arguments per lassoguide.com), PriorityQueue has no updated
    // lassoguide.com page — reference.lassosoft.com's own
    // `[PriorityQueue->Remove]` page explicitly defers to "the Lasso 8
    // Language Guide" for this type, so the 8.5 PDF's Table 10
    // ("Priority queues are always created empty... Accepts an
    // optional parameter which specifies a comparator") is still the
    // authoritative, current spec. `priorityqueue(2, 1)` must NOT
    // insert 2/1 as elements — only `->Insert` populates a
    // PriorityQueue. Regression guard against "fixing" this the same
    // way Set was fixed, which would be wrong per the actual docs.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        "[string(priorityqueue(2, 1))]|[(priorityqueue(2, 1))->size]",
        context: &context
    )
    #expect(output == "PriorityQueue: |0")
}

@Test func comparatorDirectCallReturnsZeroForAValidComparisonAndNegativeOneOtherwise() async throws {
    // Table 21's own Note: "Comparators do not return True or False...
    // A valid comparison is signaled by the return value of 0."
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        "[(compare_lessthan: 1, 2)]|[(compare_lessthan: 2, 1)]|[(compare_greaterthan: 2, 1)]",
        context: &context
    )
    #expect(output == "0|-1|0")
}

@Test func arraySortWithMatchesTheGuidesAscendingWorkedExampleAndTheMathematicallyCorrectDescendingOrder() async throws {
    // Ch. 30 p.419-420: sorting `(aaa,bbb,ccc,aa,a,b,c,bb,cc)` with
    // `\Compare_LessThan` → ascending, matching the Guide's own worked
    // example exactly: `a,aa,aaa,b,bb,bbb,c,cc,ccc`.
    //
    // The Guide's PAIRED `\Compare_GreaterThan` example, however, shows
    // `aaa,aa,a,bbb,bb,b,ccc,cc,c` — which is NOT the reverse of its own
    // ascending example (`ccc,cc,c,bbb,bb,b,aaa,aa,a`), even though
    // GreaterThan is documented as the direct opposite of LessThan
    // ("Sorts...with higher values first") and both examples sort the
    // exact same 9-element array. Verified this isn't a `pdftotext`
    // extraction artifact (checked with and without `-layout`). Since a
    // real descending sort must be a true reversal of the corresponding
    // ascending sort — sorting by `>` is definitionally the reverse of
    // sorting by `<` — the Guide's own paired example is internally
    // self-contradictory, matching this project's other found-and-
    // rejected PDF defects (Math_Div, Bytes->Contains, Set's per-
    // element-parens inconsistency). This test asserts the
    // mathematically correct reversal instead of the apparently-
    // mistranscribed PDF text.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        """
        [var('arr' = array('aaa','bbb','ccc','aa','a','b','c','bb','cc'))]\
        [$arr->SortWith(compare_lessthan)][$arr->Join(',')]|\
        [var('arr2' = array('aaa','bbb','ccc','aa','a','b','c','bb','cc'))]\
        [$arr2->SortWith(compare_greaterthan)][$arr2->Join(',')]
        """,
        context: &context
    )
    #expect(output == "a,aa,aaa,b,bb,bbb,c,cc,ccc|ccc,cc,c,bbb,bb,b,aaa,aa,a")
}

@Test func listSortWithOrdersElementsByTheGivenComparator() async throws {
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        """
        [var('myList' = (list: 'bb', 'a', 'ccc'))][$myList->SortWith(compare_lessthan)]\
        [string($myList)]
        """,
        context: &context
    )
    #expect(output == "List: a, bb, ccc")
}

@Test func arraySortWithDispatchesARealCustomComparatorTagBody() async throws {
    // Stage 7c: Array->SortWith with a genuine custom (`\TagName`-
    // referenced) comparator now actually sorts by the tag's own
    // return value, via the hand-rolled async merge sort — not just
    // the built-in-comparator path. `ReverseOrder` hand-implements the
    // same descending order `\Compare_GreaterThan` gives, independently
    // confirming the sort algorithm itself (not just single-comparison
    // dispatch, already proven by Stage 7b's Match_Comparator tests).
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        """
        [
        Define_Tag('ReverseOrder', -Required='Left', -Required='Right');
            Return((Local: 'Left') > (Local: 'Right') ? 0 | -1);
        /Define_Tag;
        var('arr' = array(3, 1, 4, 1, 5, 9, 2, 6));
        ]\
        [$arr->SortWith(\\ReverseOrder)][$arr->Join(',')]
        """,
        context: &context
    )
    #expect(output == "9,6,5,4,3,2,1,1")
}

@Test func listSortWithDispatchesARealCustomComparatorTagBody() async throws {
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        """
        [
        Define_Tag('ReverseOrder', -Required='Left', -Required='Right');
            Return((Local: 'Left') > (Local: 'Right') ? 0 | -1);
        /Define_Tag;
        var('myList' = (list: 'bb', 'a', 'ccc'));
        ]\
        [$myList->SortWith(\\ReverseOrder)][string($myList)]
        """,
        context: &context
    )
    #expect(output == "List: ccc, bb, a")
}

@Test func arraySortWithCustomComparatorIsStableForTiedElements() async throws {
    // A custom comparator that only distinguishes by even/odd leaves
    // genuine ties (both parity groups have more than one element) —
    // the merge sort must preserve each tied group's original relative
    // order, matching Swift's own `sorted(by:)` stability guarantee
    // the pre-existing sync path already relies on. Uses `%`/`<` on
    // plain NUMBERS deliberately, not strings — the raw `<` operator
    // has an unrelated, real, pre-existing bug for non-numeric (string)
    // operands, spawned as its own separate follow-up task, out of
    // scope here.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        """
        [
        Define_Tag('ByParity', -Required='Left', -Required='Right');
            Return((Local: 'Left') % 2 < (Local: 'Right') % 2 ? 0 | -1);
        /Define_Tag;
        var('arr' = array(3, 4, 1, 6));
        ]\
        [$arr->SortWith(\\ByParity)][$arr->Join(',')]
        """,
        context: &context
    )
    #expect(output == "4,6,3,1")
}

@Test func listSortWithCustomComparatorIsStableForTiedElements() async throws {
    // Sibling to the Array test above — both routes share the same
    // `LassoComparatorValue.sortedByCustomComparator`, but List's own
    // `->SortWith` registration is a separate call site (`Collections.swift`)
    // worth its own direct proof, not just inferred from Array's.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        """
        [
        Define_Tag('ByParity', -Required='Left', -Required='Right');
            Return((Local: 'Left') % 2 < (Local: 'Right') % 2 ? 0 | -1);
        /Define_Tag;
        var('myList' = (list: 3, 4, 1, 6));
        ]\
        [$myList->SortWith(\\ByParity)][string($myList)]
        """,
        context: &context
    )
    #expect(output == "List: 4, 6, 3, 1")
}

@Test func treeMapFindKeysValuesGetAndAutoStringMatchTheDaysOfWeekWorkedExample() async throws {
    // Ch. 30 pp.417-418: the DaysOfWeek worked example, verified across
    // ->Find (by key), ->Keys/->Values (sorted-by-key order, same
    // precedent as Map), ->Get(n) (1-based pair-by-position), and
    // auto-stringification (`(key)=(value)` pairs — this codebase
    // doesn't reproduce the PDF's own extra OUTER wrapping parens seen
    // on `[Variable: 'DaysOfWeek']`'s specific bare-tag output, treated
    // as that display tag's own formatting rather than part of
    // TreeMap's `outputString` contract — verified via `string(...)`
    // instead, matching this file's own established List/Queue/Stack
    // convention).
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        """
        [var('DaysOfWeek' = (treemap: 1='Sunday', 2='Monday', 3='Tuesday', 4='Wednesday', \
        5='Thursday', 6='Friday', 7='Saturday'))]\
        [$DaysOfWeek->Find(2)]|[$DaysOfWeek->Find(4)]|[$DaysOfWeek->Find(6)]|\
        [$DaysOfWeek->Keys->Join(',')]|[$DaysOfWeek->Values->Join(',')]|\
        [$DaysOfWeek->Get(1)->First]=[$DaysOfWeek->Get(1)->Second]|\
        [string($DaysOfWeek)]
        """,
        context: &context
    )
    #expect(output == """
    Monday|Wednesday|Friday|1,2,3,4,5,6,7|Sunday,Monday,Tuesday,Wednesday,Thursday,Friday,Saturday|1=Sunday|\
    TreeMap: (1)=(Sunday), (2)=(Monday), (3)=(Tuesday), (4)=(Wednesday), (5)=(Thursday), (6)=(Friday), (7)=(Saturday)
    """)
}

@Test func treeMapInsertAddsANewKeyAndReplacesAnExistingOneMatchingTheGuidesExtraSaturdayExample() async throws {
    // Ch. 30 p.418: `->Insert(8='Extra Saturday')` adds a new entry
    // (confirmed via `->Find(8)`), then `->Insert(8='Extra Sabado')`
    // REPLACES it rather than adding a duplicate (Tree maps "can only
    // store one value per key").
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        """
        [var('DaysOfWeek' = treemap)][$DaysOfWeek->Insert(8='Extra Saturday')]\
        [$DaysOfWeek->Find(8)]|[$DaysOfWeek->Size]|\
        [$DaysOfWeek->Insert(8='Extra Sabado')][$DaysOfWeek->Find(8)]|[$DaysOfWeek->Size]
        """,
        context: &context
    )
    #expect(output == "Extra Saturday|1|Extra Sabado|1")
}

@Test func treeMapRemoveDeletesByKeyMatchingTheGuidesWorkedExample() async throws {
    // Ch. 30 p.418: `$DaysOfWeek->(Remove: 8)` removes the Extra
    // Sabado entry added above.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        """
        [var('DaysOfWeek' = treemap)][$DaysOfWeek->Insert(8='Extra Sabado')][$DaysOfWeek->Size]|\
        [$DaysOfWeek->Remove(8)][$DaysOfWeek->Size]|[$DaysOfWeek->Find(8)]
        """,
        context: &context
    )
    #expect(output == "1|0|")
}

@Test func treeMapPreservesRealKeyTypesUnlikeMapWhichStringCoercesEveryKey() async throws {
    // Ch. 30 p.416: "The keys in a tree map can be any Lasso data type.
    // In a simple map all keys are converted to string values" — the
    // real, documented distinction this stage's own architectural
    // exception (`->Insert` special-cased in `Evaluator.member`,
    // bypassing the generic `.object` dispatch's argument-pre-
    // evaluation that would otherwise collapse the key to a `String`
    // label) exists specifically to preserve. An ARRAY key is the
    // clearest possible proof this actually works: if the key had been
    // silently stringified, looking it back up with an equal-but-
    // distinct array instance could never succeed. Real corpus
    // precedent for array-valued map entries: Ch. 30 p.400's own
    // `[Map: (Array: 1, 5) = (Array: 1, 2, 3, 4, 5), ...]` example.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        """
        [var('tm' = treemap)][$tm->Insert((array(1, 5))=(array(1, 2, 3, 4, 5)))]\
        [$tm->Find(array(1, 5))->Join(',')]
        """,
        context: &context
    )
    #expect(output == "1,2,3,4,5")
}

@Test func treeMapArrayKeysThatCollideUnderOutputStringConcatenationStayDistinct() async throws {
    // Regression test for a real bug code review found: `.array`'s own
    // `outputString` is a bare no-separator concatenation
    // (`Runtime.swift`'s `LassoValue.outputString`), so DISTINCT arrays
    // like `(1, 23)` and `(12, 3)` both stringify to `"123"`. The
    // ORIGINAL key-comparison implementation routed every TreeMap key
    // comparison through that same lossy `outputString`-based equality
    // (`LassoCollectionValue.equals`, shared with List/Set/Queue/
    // Stack's own element comparisons) — which would have silently
    // collapsed these two keys into one entry (`->Insert`'s second call
    // "replacing" the first instead of adding a second), exactly
    // contradicting TreeMap's headline distinction from Map. Fixed via
    // `LassoTreeMapValue.keysEqual`, which uses real structural
    // `Equatable` comparison for compound-type keys instead. Without
    // that fix this test would see `->Size` report `1`, not `2`, and
    // `->Find(array(1, 23))` would return `'B'` (the second insert's
    // value) instead of `'A'`.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        """
        [var('tm' = treemap)][$tm->Insert((array(1, 23))='A')][$tm->Insert((array(12, 3))='B')]\
        [$tm->Size]|[$tm->Find(array(1, 23))]|[$tm->Find(array(12, 3))]
        """,
        context: &context
    )
    #expect(output == "2|A|B")
}

@Test func treeMapRemoveAllWithLiteralKeyDoesNotCollideOnOutputStringConcatenation() async throws {
    // Sibling regression test to the one above, for `->RemoveAll`
    // specifically: code review found `removingAllMatchingKey` routed a
    // plain literal key through `LassoMatcherValue.matches`'s own
    // generic fallback (`LassoCollectionValue.equals`, lossy
    // `outputString`-based), bypassing `keysEqual` entirely and
    // reintroducing the exact collision the `->Insert`/`->Find` fix
    // above already closed. `RemoveAll((array(1,23)))` must remove only
    // that one key, leaving `(array(12,3))` untouched.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        """
        [var('tm' = treemap)][$tm->Insert((array(1, 23))='A')][$tm->Insert((array(12, 3))='B')]\
        [$tm->RemoveAll(array(1, 23))][$tm->Size]|[$tm->Find(array(12, 3))]
        """,
        context: &context
    )
    #expect(output == "1|B")
}

@Test func treeMapConstructorAlsoPreservesRealKeyTypesNotJustInsert() async throws {
    // Same proof as the `->Insert`-path test above, but for the
    // CONSTRUCTOR form itself (`treemap(key=value, ...)`, Table 19's
    // own documented shape) — architect review flagged that an earlier
    // version of this fix covered `->Insert`/`->Find`/`->Remove`/
    // `->RemoveAll` (special-cased in `Evaluator.member`) but left the
    // constructor going through the same label-collapsing generic
    // `.call` dispatch those methods were pulled out of, silently
    // defeating "any Lasso data type" keys for anything typed directly
    // into a `treemap(...)` call. Now special-cased in `Evaluator
    // .evaluate`'s `.call` case via `evaluateTreeMapConstructorCall`.
    // An array key (not just an integer, whose `outputString` happens
    // to coincidentally match its would-be string label) is the
    // meaningful proof here too.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        "[(treemap: (array(1, 5))=(array(1, 2, 3, 4, 5)))->Find(array(1, 5))->Join(',')]",
        context: &context
    )
    #expect(output == "1,2,3,4,5")
}

@Test func treeMapConstructorAcceptsALeadingComparatorArgument() async throws {
    // This project's own extrapolation of the Guide's intro text ("the
    // keys in a tree map can be sorted using a comparator which is
    // provided when the tree map is created", p.416) — no directly-
    // cited worked example, so this test verifies the CODE's own
    // documented behavior (a leading non-pair argument sets the sort
    // comparator) rather than a primary-source citation. `->Keys` order
    // with `Compare_GreaterThan` should be descending, not ascending.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        "[(treemap: (compare_greaterthan), 1='One', 2='Two', 3='Three')->Keys->Join(',')]",
        context: &context
    )
    #expect(output == "3,2,1")
}

@Test func mapGetReturnsAPairByPositionInTheSameSortedOrderAsKeysAndValues() async throws {
    // Ch. 30 p.402: "[Map->Get] Returns a pair from the map by integer
    // position" — using this codebase's existing sorted-by-key
    // precedent already established for `->Keys`/`->Values`, so
    // `Get(n)->First` really does correspond to `Keys[n]`.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        """
        [var('m' = map(3='Three', 1='One', 2='Two'))]\
        [$m->Get(1)->First]=[$m->Get(1)->Second]|\
        [$m->Get(2)->First]=[$m->Get(2)->Second]|\
        [$m->Get(3)->First]=[$m->Get(3)->Second]
        """,
        context: &context
    )
    #expect(output == "1=One|2=Two|3=Three")
}

@Test func iteratorWalksAnArrayForwardMatchingTheGuidesOwnWhileLoopWorkedExample() async throws {
    // Ch. 30 p.423: `Var('myIterator' = Iterator($myArray))` then a
    // `While($myIterator->atEnd == False)` loop outputting `->Value`
    // and advancing via `->Forward` — reproduction of the Guide's own
    // four-element example. The Guide's own idiom is `Null:
    // $myIterator->Forward` to suppress `->Forward`'s own boolean
    // return value — found, while writing this test, to be completely
    // unreachable in this codebase (`"null"` is hardcoded as the
    // literal `.null` VALUE token at parse time, never as a callable
    // identifier — confirmed via a minimal repro, flagged as a
    // separate out-of-scope follow-up). `[var('_' = ...)]` is used
    // instead — an assignment's own return is already void/undisplayed
    // via this codebase's existing, unrelated `Var` handling, achieving
    // the identical suppression effect through a mechanism that
    // actually works.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        """
        [var('myArray' = array('One', 'Two', 'Three', 'Four'))]\
        [var('myIterator' = iterator($myArray))]\
        [while($myIterator->atEnd == false)]\
        [$myIterator->Value] [var('_' = $myIterator->Forward)][/while]
        """,
        context: &context
    )
    #expect(output == "One Two Three Four ")
}

@Test func reverseIteratorWalksAnArrayBackwardMatchingTheGuidesOwnWorkedExample() async throws {
    // Ch. 30 pp.424-425: identical loop, but `ReverseIterator` instead
    // of `Iterator` — outputs Four, Three, Two, One.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        """
        [var('myArray' = array('One', 'Two', 'Three', 'Four'))]\
        [var('myIterator' = reverseiterator($myArray))]\
        [while($myIterator->atEnd == false)]\
        [$myIterator->Value] [var('_' = $myIterator->Forward)][/while]
        """,
        context: &context
    )
    #expect(output == "Four Three Two One ")
}

@Test func iteratorOverAMapExposesBothKeyAndValueMatchingTheGuidesOwnWorkedExample() async throws {
    // Ch. 30 p.425: same `While`/`atEnd`/`Forward` shape, but reads
    // `->Key` alongside `->Value` — "1 = Sunday", "2 = Monday", etc.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        """
        [var('myMap' = map(1='Sunday', 2='Monday', 3='Tuesday'))]\
        [var('myIterator' = iterator($myMap))]\
        [while($myIterator->atEnd == false)]\
        [$myIterator->Key] = [$myIterator->Value] [var('_' = $myIterator->Forward)][/while]
        """,
        context: &context
    )
    #expect(output == "1 = Sunday 2 = Monday 3 = Tuesday ")
}

@Test func iteratorKeyIsNullForNonMapSourcesSinceThereIsNoKeyDefined() async throws {
    // Table 24: "[Iterator->Key] Returns the key for the current
    // element IF DEFINED" — array-sourced iterators have no keys.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        "[var('it' = iterator(array('a', 'b')))][$it->Key]",
        context: &context
    )
    #expect(output == "")
}

@Test func iteratorAtBeginBackwardAndResetTrackPositionCorrectly() async throws {
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        """
        [var('it' = iterator(array('a', 'b', 'c')))]\
        [$it->AtBegin]|[var('_' = $it->Forward)][$it->AtBegin]|[var('_' = $it->Backward)][$it->AtBegin]|\
        [var('_' = $it->Forward)][var('_' = $it->Forward)][var('_' = $it->Forward)][$it->AtEnd]|\
        [var('_' = $it->Reset)][$it->AtBegin][$it->Value]
        """,
        context: &context
    )
    #expect(output == "true|false|true|true|truea")
}

@Test func iteratorLeftRightUpDownAlwaysNoOpAndTheirAtTagsAlwaysReportTrue() async throws {
    // Ch. 30 p.424, verbatim: "The left/right and up/down tags will
    // return False if a move is attempted and the test tags will
    // return True since moving in that dimension is not possible" —
    // the documented terminal behavior for every built-in type, not a
    // stub pending future work.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        """
        [var('it' = iterator(array('a')))]\
        [$it->Left]|[$it->Right]|[$it->Up]|[$it->Down]|\
        [$it->AtFarLeft]|[$it->AtFarRight]|[$it->AtTop]|[$it->AtBottom]
        """,
        context: &context
    )
    #expect(output == "false|false|false|false|true|true|true|true")
}

@Test func iteratorRemoveCurrentDeletesTheCurrentElementFromItsOwnSnapshot() async throws {
    // No worked example exists for `->RemoveCurrent` (see
    // `Iterator.swift`'s own doc comment) — this test verifies the
    // implemented behavior (remove, then advance) rather than a
    // primary-source citation.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        """
        [var('it' = iterator(array('a', 'b', 'c')))]\
        [var('_' = $it->RemoveCurrent)][$it->Value]
        """,
        context: &context
    )
    #expect(output == "c")
}

@Test func iteratorInsertAtCurrentInsertsAtTheCurrentPositionInItsOwnSnapshot() async throws {
    // Same "no worked example" caveat as `->RemoveCurrent` above.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        """
        [var('it' = iterator(array('a', 'b', 'c')))]\
        [var('_' = $it->Forward)][var('_' = $it->InsertAtCurrent('X'))][$it->Value]
        """,
        context: &context
    )
    #expect(output == "X")
}

@Test func listSetTreeMapIteratorsMatchTheirOwnCollectionsTraversalOrder() async throws {
    // Table 23's own "e.g." list names array/list/map/set/treemap as
    // built-in `->Iterator`-supporting types — this codebase
    // implements it uniformly across every collection type from
    // Stages 1-2 instead (see `Iterator.swift`'s own doc comment for
    // why), but this test focuses on the three Table-23-named compound
    // types specifically. Set/TreeMap both iterate in their own
    // natural sorted order (never insertion order).
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        """
        [var('l' = (list: 'x', 'y'))][var('li' = $l->Iterator)]\
        [$li->Value][var('_' = $li->Forward)][$li->Value]|\
        [var('s' = set)][$s->Insert('Beta')][$s->Insert('Alpha')][var('si' = $s->Iterator)]\
        [$si->Value][var('_' = $si->Forward)][$si->Value]|\
        [var('tm' = (treemap: 2='Two', 1='One'))][var('tmi' = $tm->Iterator)]\
        [$tmi->Key]=[$tmi->Value]
        """,
        context: &context
    )
    #expect(output == "xy|AlphaBeta|1=One")
}

@Test func queueAndStackIteratorsWalkTheirOwnStoredOrderWithoutMutatingTheSource() async throws {
    // Not among Table 23's own "e.g." list, but implemented uniformly
    // (disclosed design choice, see `Iterator.swift`'s own doc
    // comment) — importantly, unlike `->Get`, obtaining an iterator
    // must NOT drain the queue/stack (`->Size` stays 2 afterward).
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        """
        [var('q' = queue)][$q->Insert('One')][$q->Insert('Two')][var('qi' = $q->Iterator)]\
        [$qi->Value][var('_' = $qi->Forward)][$qi->Value]|[$q->Size]
        """,
        context: &context
    )
    #expect(output == "OneTwo|2")
}

@Test func pairFirstAndSecondCanBeUsedAsAssignmentTargetsMatchingTheGuidesOwnWorkedExample() async throws {
    // Ch. 30 Table 9, p.404: "[Pair->First]/[Pair->Second] ... Can be
    // used as the left parameter of an assignment operator" — verified
    // against the Guide's own worked example verbatim: create
    // `(Pair: 'First_Name'='John')`, set `->First = 'Last_Name'` and
    // `->Second = 'Doe'`, read back "Last_Name: Doe". `Pair` is a
    // VALUE-type `LassoValue` case (not `.object`-wrapped) — this only
    // works via the new recursive rebuild-and-reassign path in
    // `Evaluator.assign`, not a generic object-field write.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        """
        [var('Test_Pair' = (pair: 'First_Name'='John'))]\
        [$Test_Pair->First = 'Last_Name']\
        [$Test_Pair->Second = 'Doe']\
        [$Test_Pair->First] + [$Test_Pair->Second]
        """,
        context: &context
    )
    #expect(output == "Last_Name + Doe")
}

@Test func pairSizeAlwaysReturnsTwoAndGetExtractsFirstAndSecondByPosition() async throws {
    // Ch. 30 p.404 Note: "the [Pair->Size] tag always returns 2 and
    // [Pair->(Get:1)] and [Pair->(Get:2)] work to extract the first and
    // second elements from a pair."
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        "[(pair: 'First_Name'='John')->Size]|[(pair: 'First_Name'='John')->Get(1)]|[(pair: 'First_Name'='John')->Get(2)]",
        context: &context
    )
    #expect(output == "2|First_Name|John")
}

@Test func pairAutoStringifiesAsKeyEqualsValueEachHalfParenthesized() async throws {
    // Ch. 30 p.404's own worked example: `[Variable: 'Test_Pair']` on
    // `(Pair: 'First_Name'='John')` → `(Pair: (First_Name)=(John))` —
    // this codebase reproduces the inner `(key)=(value)` shape (no
    // surrounding spaces) via `string(...)` rather than the outer
    // wrapping parens, matching the same established treatment as
    // `TreeMap`'s own bare-display worked example (see
    // `LassoValue.outputString`'s `.pair` case doc comment).
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        "[string((pair: 'First_Name'='John'))]",
        context: &context
    )
    #expect(output == "(First_Name)=(John)")
}

@Test func queueFirstCanBeUsedAsAnAssignmentTargetMatchingTheGuidesOwnWorkedExample() async throws {
    // Ch. 30 p.409-410: "[Queue->First] returns the first element of
    // the queue BY REFERENCE so the value of the element can be
    // changed" — insert One, Two; `->First = 'Three'`; `->First` reads
    // back "Three". Mutates the `.object`-wrapped Queue's own
    // `_elements` array in place (front position), no recursive
    // reassignment needed unlike Pair.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        """
        [var('myQueue' = queue)][$myQueue->Insert('One')][$myQueue->Insert('Two')]\
        [$myQueue->First = 'Three'][$myQueue->First]
        """,
        context: &context
    )
    #expect(output == "Three")
}

@Test func stackFirstCanBeUsedAsAnAssignmentTargetMatchingTheGuidesOwnWorkedExample() async throws {
    // Ch. 30 p.415: same shape as Queue's own worked example above, but
    // Stack's `->First` reads the LIFO top (`.last`), so `->First=`
    // must write the LAST element, not the first.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        """
        [var('myStack' = stack)][$myStack->Insert('One')][$myStack->Insert('Two')]\
        [$myStack->First = 'Three'][$myStack->First]
        """,
        context: &context
    )
    #expect(output == "Three")
}

@Test func setGetCanBeUsedAsAnAssignmentTargetToOverwriteAPositionInPlace() async throws {
    // Ch. 30 Table 16: "[Set->Get] ... This tag can be used as the left
    // parameter of an assignment operator to set an element of the
    // set." No worked example exists to verify against (see
    // `Evaluator.assign`'s own doc comment) — this is a direct
    // positional overwrite, not a re-insert-and-resort, since Table 16
    // doesn't address how (or whether) sortedness should be maintained
    // through this path.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        """
        [var('mySet' = set)][$mySet->Insert('Alpha')][$mySet->Insert('Beta')][$mySet->Insert('Gamma')]\
        [$mySet->Get(2) = 'Replaced'][string($mySet)]
        """,
        context: &context
    )
    #expect(output == "Set: (Alpha), (Replaced), (Gamma)")
}

@Test func pairHasMethodReportsTrueForSizeAndGetNotJustFirstAndSecond() async throws {
    // Regression test for a real bug architect review found: adding
    // real `.pair` dispatch cases for `->Size`/`->Get` to
    // `Evaluator.member` isn't enough on its own — `->HasMethod`
    // introspection reads a SEPARATE mirror table
    // (`primitiveMethodNames["pair"]`) that must be kept in sync by
    // hand (its own doc comment explicitly warns of exactly this drift
    // risk). The mirror still listed only `["first", "second"]` after
    // `->Size`/`->Get` were added, so `->HasMethod` silently
    // under-reported `false` for two methods that actually worked.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        """
        [(pair: 'a'='b')->HasMethod('first')]|[(pair: 'a'='b')->HasMethod('second')]|\
        [(pair: 'a'='b')->HasMethod('size')]|[(pair: 'a'='b')->HasMethod('get')]|\
        [(pair: 'a'='b')->HasMethod('nonexistent')]
        """,
        context: &context
    )
    #expect(output == "true|true|true|true|false")
}

@Test func mapGetCanBeUsedAsAnAssignmentTargetToOverwriteAValueAtAPosition() async throws {
    // Cross-checked directly against lassoguide.com's Lasso 9
    // documentation for `map->get`/`->get=` — that real contract turns
    // out to be a much bigger redesign than "add a setter" (key-based,
    // returns a bare value not a pair, fails on a missing key), which
    // would break the already-shipped, worked-example-verified 8.5
    // `->Get(n)` behavior (position-based, pair-returning) with no
    // user sign-off on such a disruptive change. Implemented instead as
    // the narrower reading: `->Get(n) = value` reassigns the VALUE half
    // of the pair at that position, same shape as `Set->Get(n)=`. `.map`
    // is a value type, so this only works via the same recursive
    // rebuild-and-reassign path `Pair->First=` already established.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        """
        [var('m' = map(1='One', 2='Two', 3='Three'))]\
        [$m->Get(2) = 'Replaced']\
        [$m->Get(1)->Second]|[$m->Get(2)->Second]|[$m->Get(3)->Second]
        """,
        context: &context
    )
    #expect(output == "One|Replaced|Three")
}

@Test func mapGetAssignmentOutOfRangePositionIsANoOp() async throws {
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        """
        [var('m' = map(1='One'))][$m->Get(99) = 'X'][$m->Get(0) = 'Y']\
        [$m->Size]|[$m->Get(1)->Second]
        """,
        context: &context
    )
    #expect(output == "1|One")
}

@Test func mapGetAssignmentOnANegativePositionOrAnEmptyMapIsAlsoANoOp() async throws {
    // Widens the out-of-range coverage above per code review's own
    // nit — a negative position (not just 0/beyond-count) and an
    // entirely empty map (where `sortedKeys` itself is empty) are
    // both distinct edge cases worth exercising explicitly rather than
    // trusting they're covered by inspection alone.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        """
        [var('m' = map(1='One'))][$m->Get(-1) = 'X'][$m->Size]|[$m->Get(1)->Second]|\
        [var('empty' = map)][$empty->Get(1) = 'Y'][$empty->Size]
        """,
        context: &context
    )
    #expect(output == "1|One|0")
}

@Test func containsOperatorFixedBugWhereArrayMembershipDegradedToStringConcatenation() async throws {
    // Regression test for the real, pre-existing bug this stage's own
    // scoping pass found and fixed: `>>`'s old implementation was pure
    // `left.outputString.contains(right.outputString)` with no
    // `.array` branching at all — `(Array: 12, 3) >> 23` would have
    // false-positived, since the array's own concatenated
    // `outputString` ("123") coincidentally contains "23" as a
    // substring even though no element of the array is literally 23.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        "[(array: 12, 3) >> 23]|[(array: 1, 2, 3, 4, 5, 6, 7) >> 7]",
        context: &context
    )
    #expect(output == "false|true")
}

@Test func matchRangeAndNotRangeWorkWithTheContainsOperatorMatchingTheGuidesOwnWorkedExamples() async throws {
    // Ch. 30 p.421: `(Array: 1..7) >> (Match_Range: 1, 4)` → True;
    // `>> (Match_Range: 8, 10)` → False. Range is inclusive both ends
    // ("equal to either end-value or within the specified range").
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        """
        [(array: 1, 2, 3, 4, 5, 6, 7) >> (match_range: 1, 4)]|\
        [(array: 1, 2, 3, 4, 5, 6, 7) >> (match_range: 8, 10)]|\
        [(array: 1, 2, 3, 4, 5, 6, 7) >> (match_notrange: 8, 10)]
        """,
        context: &context
    )
    #expect(output == "true|false|true")
}

@Test func matchRegExpAndNotRegExpWorkWithTheContainsOperatorMatchingTheGuidesOwnWorkedExamples() async throws {
    // Ch. 30 p.421: `(Array: 'one','two') >> (Match_RegExp: 'o')` →
    // True (both contain 'o'); `>> (Match_RegExp: 'f')` → False
    // (neither word contains an 'f').
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        """
        [(array: 'one', 'two') >> (match_regexp: 'o')]|\
        [(array: 'one', 'two') >> (match_regexp: 'f')]|\
        [(array: 'one', 'two') >> (match_notregexp: 'f')]
        """,
        context: &context
    )
    #expect(output == "true|false|true")
}

@Test func matchComparatorRhsAndLhsFormsMatchTheGuidesOwnWorkedExamples() async throws {
    // Ch. 30 p.421-422, all four worked examples verbatim:
    // `(Array:1,2,3) >> (Match_Comparator: \Compare_LessThan, -RHS=5)`
    // → True (every element < 5); `-LHS=5` → False (5 is not less than
    // any of 1,2,3); `\Compare_EqualTo, -RHS=3` → True (array contains
    // 3); `\Compare_StrictEqualTo, -RHS='3'` → False (no element is
    // strictly, type-wise, equal to the STRING '3').
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        """
        [(array: 1, 2, 3) >> (match_comparator: (compare_lessthan), -rhs=5)]|\
        [(array: 1, 2, 3) >> (match_comparator: (compare_lessthan), -lhs=5)]|\
        [(array: 1, 2, 3) >> (match_comparator: (compare_equalto), -rhs=3)]|\
        [(array: 1, 2, 3) >> (match_comparator: (compare_strictequalto), -rhs='3')]
        """,
        context: &context
    )
    #expect(output == "true|false|true|false")
}

@Test func removeAllWithMatchRangeMatchRegExpAndMatchComparatorMatchTheGuidesOwnWorkedExamples() async throws {
    // Ch. 30 p.421-422, all three ->RemoveAll-with-a-matcher worked
    // examples: `Match_Range(2,4)` on `(1..7)` leaves `(1,5,6,7)`;
    // `Match_RegExp('\bT')` removes weekday names starting with T;
    // `Match_Comparator(\Compare_LessThan, -RHS=5)` on `(1..7)` leaves
    // `(5,6,7)`.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        """
        [var('a' = array(1, 2, 3, 4, 5, 6, 7))][$a->RemoveAll(match_range(2, 4))][$a->Join(',')]|\
        [var('days' = array('Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday'))]\
        [$days->RemoveAll(match_regexp('\\\\bT'))][$days->Join(',')]|\
        [var('b' = array(1, 2, 3, 4, 5, 6, 7))]\
        [$b->RemoveAll(match_comparator((compare_lessthan), -rhs=5))][$b->Join(',')]
        """,
        context: &context
    )
    #expect(output == "1,5,6,7|Monday,Wednesday,Friday|5,6,7")
}

@Test func matchComparatorDispatchesARealCustomTagBodyNotJustBuiltIns() async throws {
    // Stage 7b: `Match_Comparator` wrapping a `\TagName` reference to a
    // genuine user-`Define_Tag`'d comparator now actually RUNS that
    // tag's own body (via LassoTagInvocationService, Stage 7a) rather
    // than falling back to "unrecognized comparator" behavior. `IsEven`
    // ignores its `-RHS`/`-LHS` operand entirely and only inspects
    // `Left` — proves real per-element dispatch, not a fixed/cached
    // result, since different elements must genuinely produce different
    // outcomes.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        """
        [
        Define_Tag('IsEven', -Required='Left', -Required='Right');
            Return((Local: 'Left') % 2 == 0 ? 0 | -1);
        /Define_Tag;
        var('a' = array(1, 2, 3, 4, 5));
        ]\
        [(array: 1, 2, 3, 4, 5) >> (match_comparator: \\IsEven)]|\
        [$a->Contains(match_comparator(\\IsEven))]|\
        [var('found' = $a->Find(match_comparator(\\IsEven)))][$found->Join(',')]|\
        [$a->RemoveAll(match_comparator(\\IsEven))][$a->Join(',')]
        """,
        context: &context
    )
    #expect(output == "true|true|2,4|1,3,5")
}

@Test func matchComparatorCustomDispatchHonorsRhsAndLhsFormsLikeBuiltIns() async throws {
    // Same -RHS/-LHS asymmetry the built-in-comparator worked example
    // proves (matchComparatorRhsAndLhsFormsMatchTheGuidesOwnWorkedExamples
    // above), but for a genuine custom tag: `IsLessThan` mirrors
    // \Compare_LessThan's own semantics by hand, confirming -RHS means
    // evaluate(element, RHS) and -LHS means evaluate(LHS, element) for
    // a REAL dispatched tag body too, not just the built-in path.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        """
        [
        Define_Tag('IsLessThan', -Required='Left', -Required='Right');
            Return((Local: 'Left') < (Local: 'Right') ? 0 | -1);
        /Define_Tag;
        ]\
        [(array: 1, 2, 3) >> (match_comparator: \\IsLessThan, -rhs=5)]|\
        [(array: 1, 2, 3) >> (match_comparator: \\IsLessThan, -lhs=5)]
        """,
        context: &context
    )
    #expect(output == "true|false")
}

@Test func matchComparatorCustomDispatchOnAnEmptyCollectionNeverInvokesTheTag() async throws {
    // No element means the comparator tag body never runs at all — not
    // "runs zero times but somehow still returns a sane default,"
    // genuinely never invoked. Uses a comparator that would throw if
    // ever actually called, so a wrong invocation would fail the test
    // rather than silently passing.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        """
        [
        Define_Tag('AlwaysThrows', -Required='Left', -Required='Right');
            NoSuchTagAtAll();
        /Define_Tag;
        var('empty' = array);
        ]\
        [$empty->Contains(match_comparator(\\AlwaysThrows))]
        """,
        context: &context
    )
    #expect(output == "false")
}

@Test func matchComparatorCustomDispatchPropagatesAnErrorThrownInsideTheTagBody() async throws {
    // A custom comparator tag that itself throws mid-evaluation must
    // abort the whole ->Contains/->Find/->RemoveAll/`>>` operation, not
    // get silently swallowed or treated as "no match."
    var context = LassoContext()
    await #expect(throws: LassoRuntimeError.unknownFunction("NoSuchTagAtAll")) {
        _ = try await LassoRenderer().render(
            """
            [
            Define_Tag('Broken', -Required='Left', -Required='Right');
                NoSuchTagAtAll();
            /Define_Tag;
            ]\
            [(array: 1, 2, 3) >> (match_comparator: \\Broken)]
            """,
            context: &context
        )
    }
}

@Test func matchComparatorCustomDispatchWithTooFewDeclaredArgumentsThrowsArityMismatch() async throws {
    // A comparator tag declaring MORE required parameters than the
    // fixed [left, right] this dispatch path always supplies must fail
    // loudly (LassoTagInvocationService's own disclosed scope limit —
    // no default-parameter-expression evaluation), not silently bind a
    // wrong/missing value.
    var context = LassoContext()
    await #expect(throws: LassoRuntimeError.tagInvocationArityMismatch("NeedsThree")) {
        _ = try await LassoRenderer().render(
            """
            [
            Define_Tag('NeedsThree', -Required='Left', -Required='Right', -Required='Extra');
                Return(-1);
            /Define_Tag;
            ]\
            [(array: 1, 2, 3) >> (match_comparator: \\NeedsThree)]
            """,
            context: &context
        )
    }
}

@Test func iteratorWithAMatcherFiltersElementsMatchingTheGuidesOwnWorkedExample() async throws {
    // Ch. 30 p.426: `Iterator($myArray, (Match_Range: 'a', 'm'))` on
    // `('One','Two','Three','Four')` — the Guide's own stated result
    // is "Four" alone, taken as ground truth rather than re-derived.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        """
        [var('myArray' = array('One', 'Two', 'Three', 'Four'))]\
        [var('myIterator' = iterator($myArray, (match_range: 'a', 'm')))]\
        [while($myIterator->atEnd == false)]\
        [$myIterator->Value] [var('_' = $myIterator->Forward)][/while]
        """,
        context: &context
    )
    #expect(output == "Four ")
}

@Test func listAndSetContainsAndRemoveAllAreMatcherAwareTooNotJustArray() async throws {
    // Not a Table-22-specific worked example (those all use Array),
    // but Table 22's own intro says Matchers work "with the
    // […->Iterator], […->RemoveAll]" tags "of a compound data type" —
    // generically, not Array-only — this test verifies List/Set's own
    // already-existing ->Contains/->RemoveAll actually got the same
    // extension, not just Array's.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        """
        [var('l' = (list: 1, 2, 3, 4, 5))][$l->Contains(match_range(2, 4))]|\
        [$l->RemoveAll(match_range(2, 4))][$l->Join(',')]|\
        [var('s' = set)][$s->Insert('one')][$s->Insert('two')]\
        [$s->Contains(match_regexp('o'))]|[$s->RemoveAll(match_regexp('o'))][string($s)]
        """,
        context: &context
    )
    #expect(output == "true|1,5|true|Set: ")
}

@Test func tagInvocationServiceInvokesADefinedTagWithPositionalArguments() async throws {
    // Direct Swift-level test of the new `LassoTagInvocationService`
    // plumbing (Providers.swift/Renderer.swift) — nothing in Lasso
    // source can reach it yet (no comparator/matcher dispatch wired to
    // it in this pass), so this exercises it the only way currently
    // possible: define a tag via a real render (populating
    // context.tagRegistry AND wiring context.tagInvocationService via
    // RendererEngine.init), then invoke it directly with pre-evaluated
    // positional arguments, bypassing Evaluator.invokeCustomTag's own
    // AST-argument-evaluation path entirely.
    var context = LassoContext()
    _ = try await LassoRenderer().render(
        """
        [
        Define_Tag('AddTwo', -Required='A', -Required='B');
            Return((Local: 'A') + (Local: 'B'));
        /Define_Tag;
        ]
        """,
        context: &context
    )
    let definition = try #require(context.tagRegistry.tag(named: "AddTwo"))
    let service = try #require(context.tagInvocationService)
    let result = try await service.invoke(definition, positionalArguments: [.integer(3), .integer(4)], context: &context)
    #expect(result == .integer(7))
}

@Test func tagInvocationServiceThrowsOnArityMismatchRatherThanSilentlyDefaulting() async throws {
    // Deliberate scope limit (see LassoTagInvocationService's own doc
    // comment): unlike Evaluator.invokeCustomTag's general call-site
    // binding, this narrower path does not evaluate default-parameter
    // expressions — supplying fewer positional arguments than the
    // definition declares must fail loudly, not silently bind the
    // missing parameter to .null or some other default.
    var context = LassoContext()
    _ = try await LassoRenderer().render(
        """
        [
        Define_Tag('NeedsTwo', -Required='A', -Required='B');
            Return((Local: 'A') + (Local: 'B'));
        /Define_Tag;
        ]
        """,
        context: &context
    )
    let definition = try #require(context.tagRegistry.tag(named: "NeedsTwo"))
    let service = try #require(context.tagInvocationService)
    await #expect(throws: LassoRuntimeError.tagInvocationArityMismatch("NeedsTwo")) {
        _ = try await service.invoke(definition, positionalArguments: [.integer(3)], context: &context)
    }
}

@Test func tagInvocationServiceRestoresCallerLocalsAfterInvocation() async throws {
    // The narrower invoker must still honor the same fresh-local-scope
    // isolation Evaluator.invokeCustomTag provides — a called tag's own
    // #locals must not leak into or clobber the caller's. Sets the
    // "before" local directly via `LassoContext.set(...)` (Swift-level)
    // rather than through a rendered `Local(...)` statement, since this
    // is testing the invocation SERVICE's own scope isolation, not
    // Lasso-source parsing.
    var context = LassoContext()
    _ = try await LassoRenderer().render(
        """
        [
        Define_Tag('SetLocal');
            Local('untouched' = 'inside');
            Return('done');
        /Define_Tag;
        ]
        """,
        context: &context
    )
    context.set(.string("before"), for: "untouched", scope: .local)
    let definition = try #require(context.tagRegistry.tag(named: "SetLocal"))
    let service = try #require(context.tagInvocationService)
    let result = try await service.invoke(definition, positionalArguments: [], context: &context)
    #expect(result == .string("done"))
    #expect(context.value(for: "untouched", scope: .local) == .string("before"))
}

@Test func tagInvocationServiceDoesNotDriftBindingsWhenAParameterNameIsUnresolvable() async throws {
    // Regression test for a real gap code review found: the binding
    // loop originally used its `enumerated()` loop index directly into
    // `positionalArguments`, rather than a separate counter that only
    // advances on an actual bind (matching Evaluator.bindParameters's
    // own defensive shape). A declared parameter whose name can't be
    // resolved (unreachable for well-formed `-Required=`/`-Optional=`
    // declarations, but structurally legal — e.g. a bare literal) would
    // have silently shifted every SUBSEQUENT parameter's binding one
    // position off, a wrong-value bug that wouldn't throw. Simulates
    // that shape directly by prepending a nameless parameter
    // (`LassoMethodDispatcher.parameterMetadata` only resolves a name
    // for identifier/string/variable/`::`-typed shapes, so a bare
    // integer literal parameter resolves to `name == nil`) ahead of two
    // real, named parameters.
    var context = LassoContext()
    _ = try await LassoRenderer().render(
        """
        [
        Define_Tag('AddTwo', -Required='A', -Required='B');
            Return((Local: 'A') + (Local: 'B'));
        /Define_Tag;
        ]
        """,
        context: &context
    )
    let original = try #require(context.tagRegistry.tag(named: "AddTwo"))
    let withLeadingUnnamedParameter = LassoCustomTagDefinition(
        name: original.name,
        parameters: [LassoArgument(label: nil, value: .integer(999))] + original.parameters,
        body: original.body
    )
    let service = try #require(context.tagInvocationService)
    let result = try await service.invoke(
        withLeadingUnnamedParameter, positionalArguments: [.integer(3), .integer(4)], context: &context
    )
    #expect(result == .integer(7))
}

@Test func elseLessArrowIfNestedInALargerIfElseChainDoesNotSwallowTheOuterElse() async throws {
    // Real corpus: includes/efs_process.lasso's PayPal branch is a
    // self-contained, else-less `if(...) => { ... }` nested inside a
    // larger if(gift)/else(if(invoice)/else(paypal)/else(creditcard)/if)
    // chain. ScriptBodyParser's peekIsElseKeyword() used to defer the
    // inner arrow-if's closing brace whenever ANY `else` followed it,
    // even one that belonged to the outer chain -- permanently leaving
    // the inner if unpopped, so BlockBuilder's later re-nesting pass
    // attached the outer's real else (and everything after it) to the
    // wrong, inner if instead. This silently truncated the outer
    // chain, dropping the whole "creditcard" branch below.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        """
        <?lasso
        if($mode == 'gift')
          'gift'
        else($mode == 'paypal')
          if($paypal_ready) => {
            'entering paypal'
          }
          'after paypal block'
        else
          'entering creditcard'
        /if
        ?>
        """,
        context: &context
    )
    #expect(output.contains("entering creditcard"))
}

@Test func selfContainedArrowIfElseNestedInALargerChainStillWorksBothWays() async throws {
    // Companion case to the above -- an arrow-if that DOES have its own
    // arrow-style else must still correctly attach that else to ITSELF,
    // not to the outer chain, in both the entered and not-entered state.
    var context = LassoContext()
    let entered = try await LassoRenderer().render(
        """
        <?lasso
        if('x' == 'x')
          if(true) => {
            'inner-true'
          } else => {
            'inner-false'
          }
          'after-inner'
        else
          'outer-false-branch'
        /if
        ?>
        """,
        context: &context
    )
    #expect(entered.contains("inner-true"))
    #expect(!entered.contains("inner-false"))
    #expect(entered.contains("after-inner"))

    var context2 = LassoContext()
    let notEntered = try await LassoRenderer().render(
        """
        <?lasso
        if('x' == 'x')
          if(false) => {
            'inner-true'
          } else => {
            'inner-false'
          }
          'after-inner'
        else
          'outer-false-branch'
        /if
        ?>
        """,
        context: &context2
    )
    #expect(notEntered.contains("inner-false"))
    #expect(!notEntered.contains("inner-true"))
    #expect(notEntered.contains("after-inner"))
}

@Test func leadingDotDecimalLiteralsParseAsNumbersNotSelfShorthandMemberAccess() async throws {
    // Real corpus: includes/efs_process.lasso calls
    // `math_round(field('order_grandtotal'), .01)` -- the bare `.01`
    // argument. The lexer only recognized numbers starting with a
    // digit, so `.01` fell through to `.symbol(".")`, which
    // parsePrimary's self-shorthand member-access case
    // (`.methodName` -> `self->methodName`) happily accepted, producing
    // a nonsense `.member(self, "<unknown>")` node instead of a number.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        "[math_round(14.018374999999999, .01)]|[.5]|[-.25]",
        context: &context
    )
    #expect(output == "14.020000|0.500000|-0.250000")
}

@Test func selfShorthandMemberAccessStillWorksAlongsideTheLeadingDotDecimalFix() async throws {
    // Guards against the leading-dot-decimal fix regressing the actual
    // legitimate construct it could be confused with: `.methodName`
    // inside a custom type's method body, shorthand for
    // `self->methodName`.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        """
        <?lassoscript
        define Widget => type {
            data public name::string
            public onCreate(name::string) => {
                self->name = #name
            }
            public shout() => {
                return .name + '!'
            }
        }
        local(widget::Widget = Widget('Ada'))
        ?>
        [#widget->shout()]
        """,
        context: &context
    )
    #expect(output.trimmingCharacters(in: .whitespacesAndNewlines) == "Ada!")
}

@Test func blockTagPastTheFirstStatementInASquareBracketSpanStillBecomesARealBlock() async throws {
    // Real corpus: includes/mini_cart.lasso's `[var(What_Action::string =
    // $function) if(var_defined('cart_id') && $cart_id != '') ...
    // records ... /if]` — an ordinary `var(...)` assignment precedes the
    // real `if`, and both the `if` and the nested `records` loop opened
    // here don't close until much later, in their own separate
    // single-tag bracket spans (`[/records]`, `[/if]`) after intervening
    // literal HTML. `emitCode`'s square-bracket dispatch only checked
    // whether the span's FIRST statement was itself a block-tag call
    // (the already-handled `[if(...) ... else ... /if]` shape) — a block
    // tag appearing anywhere past the first position fell through to the
    // flat `ExpressionParser` + `.code(...)` path, which has no concept
    // of blocks: "if"/"records" parsed as ordinary calls, never became
    // `.tag(...)` nodes `BlockBuilder` could pair with their real
    // closers, and evaluation crashed trying to call them as functions
    // (`unknownFunction("if")`).
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        """
        [
          var(marker::string = 'seen')
          if(true)
            'body-before-close'
        ]
        <div>middle html</div>
        [
          if(true)
            'nested-yes'
          else
            'nested-no'
          /if
        ]
        tail
        [
        /if
        ]
        """,
        context: &context
    )
    #expect(output.contains("body-before-close"))
    #expect(output.contains("nested-yes"))
    #expect(!output.contains("nested-no"))
    #expect(output.contains("middle html"))
    #expect(output.contains("tail"))
}

@Test func recordsLoopPastTheFirstStatementInASquareBracketSpanStillClosesAcrossLaterSpans() async throws {
    // Companion case to the above, using `records`/`/records` (a bare
    // `.bareIdentifier`-form block, unlike `if`'s `.bareCondition` form)
    // instead of `if` — matching mini_cart.lasso's actual inner loop,
    // which is the specific construct BlockBuilder reported as an
    // "Unexpected closing tag records" diagnostic before this fix (the
    // bare-opened `records` never became a `.tag(...)` node, so its
    // later, separate `[/records]` span had no open to match). The
    // ordinary `var(...)` statement preceding the bare `records` here
    // (matching mini_cart.lasso's own `var(marker...) records` shape) is
    // what makes `records` NOT the span's first statement.
    let executor = PerfectCRUDLassoExecutor { _, _, _ in
        DynamicResult(
            rows: [
                DynamicRow(["mfr_style_no": .string("A")]),
                DynamicRow(["mfr_style_no": .string("B")]),
            ],
            statement: "SELECT ..."
        )
    }
    var context = LassoContext(inlineProvider: LassoDynamicInlineProvider(
        executor: executor,
        datasourceAliases: ["catalog_mysql": "catalog"]
    ))
    let output = try await LassoRenderer().render(
        """
        [inline(-database='catalog_mysql', -table='skus', -findall)]
        [
          var(marker::string = 'seen')
          records
        ]
        [field('mfr_style_no')]|
        [
          /records
        ]
        [/inline]
        """,
        context: &context
    )
    let compact = output.components(separatedBy: .whitespacesAndNewlines).joined()
    #expect(compact == "A|B|")
}

@Test func decimalToStringDefaultsToSixDecimalPlacesMatchingTheLanguageGuidesOwnDocumentedRule() async throws {
    // lassoguide.com Math chapter, "Creating Decimal Objects": "The
    // precision of a decimal value when converted to a string is always
    // displayed as six decimal places even though the actual precision
    // of the number may vary based on the size of the number and its
    // internal representation." This governs `string()`, bare bracket
    // output, and `+` string concatenation (all of which route through
    // `LassoValue.outputString`), and `decimal->asString` with no
    // `-precision` argument (`formattedNumber`'s default). Both
    // previously fell back to Swift's raw `String(Double)`, which prints
    // the shortest round-trippable representation instead -- leaking
    // IEEE-754 binary-fraction noise straight through for any value not
    // exactly representable in binary (almost every two-decimal money
    // amount). Found live: a real order's `order_grandtotal`
    // (`14.018374999999999`, after round-tripping through ordinary Lasso
    // arithmetic) leaked this exact noise into a payment gateway's
    // amount field via a bare `$order_grandtotal` reference.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        "[string(14.018374999999999)]|[string(0.1 + 0.2)]|[14.02->asString]|[(59.99 * 0.89)->asString]",
        context: &context
    )
    #expect(output == "14.018375|0.300000|14.020000|53.391100")
}

@Test func integerAsStringWithNoPrecisionPrintsABareIntegerNotADoubleWithATrailingDotZero() async throws {
    // Companion regression to the decimal default above -- `formattedNumber`
    // is shared by both `integer->asString` and `decimal->asString`, and
    // integers have no six-decimal-place rule at all (real Lasso just
    // prints the bare whole number). Previously the shared fallback
    // (`String(value)` on the `Double` both branches flatten to) applied
    // uniformly regardless of invocant type, so `123->asString` produced
    // `"123.0"`, not `"123"`.
    var context = LassoContext()
    let output = try await LassoRenderer().render("[123->asString]", context: &context)
    #expect(output == "123")
}

// MARK: - String method expansion (Ch. 25 Tables 3/5/11 members, Tables 4/6/10/12 free tags)

@Test func stringRemoveDeletesACountedRangeStartingAtA1BasedOffset() async throws {
    // Ch. 25 Table 3: "The first parameter is the offset at which to
    // start removing characters. The second parameter is the number of
    // characters to remove." No worked example in the Guide itself for
    // the member form; hand-verified against "Alpha": removing 2
    // characters starting at position 2 ('l','p') leaves "A" + "ha".
    var context = LassoContext()
    let output = try await LassoRenderer().render("['Alpha'->(Remove: 2, 2)]", context: &context)
    #expect(output == "Aha")
}

@Test func stringRemoveWithNoCountRemovesToTheEndOfTheString() async throws {
    // Ch. 25 Table 3: count "Defaults to removing to the end of the
    // string." "Alpha" from position 3 onward ('p','h','a') removed
    // leaves "Al".
    var context = LassoContext()
    let output = try await LassoRenderer().render("['Alpha'->(Remove: 3)]", context: &context)
    #expect(output == "Al")
}

@Test func stringMergeInsertsAWholeMergeStringAtA1BasedLocation() async throws {
    // Ch. 25 Table 3: "Inserts a merge string into the string...the
    // location at which to insert the merge string and the string to
    // insert." Hand-verified: inserting "XY" before position 3 of
    // "Alpha" ('p') yields "Al" + "XY" + "pha".
    var context = LassoContext()
    let output = try await LassoRenderer().render("['Alpha'->(Merge: 3, 'XY')]", context: &context)
    #expect(output == "AlXYpha")
}

@Test func stringMergeWithOffsetAndCountInsertsOnlyASliceOfTheMergeString() async throws {
    // Ch. 25 Table 3: "Optional third and fourth parameters specify an
    // offset into the merge string and number of characters of the
    // merge string to insert." From "ABCDE", a 1-based offset of 2 with
    // count 2 selects "BC" (skipping 'A', taking 'B','C').
    var context = LassoContext()
    let output = try await LassoRenderer().render("['Alpha'->(Merge: 3, 'ABCDE', 2, 2)]", context: &context)
    #expect(output == "AlBCpha")
}

@Test func stringFoldcaseMutatesTheInvocantToACaseInsensitiveComparisonForm() async throws {
    // Ch. 25 Table 5: "Converts all characters in the string for a
    // case-insensitive comparison. Modifies the string and returns no
    // value." Implemented as lowercasing (see `->foldcase`'s own doc
    // comment for why this is the closest available approximation
    // without a real ICU case-fold API).
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        "[var('s' = 'TEST')][$s->(Foldcase)][$s]", context: &context
    )
    #expect(output == "test")
}

@Test func stringToLowerToUpperToTitleMutateOnlyTheSingleCharacterAtTheGivenPosition() async throws {
    // Ch. 25 Table 5: `->toLower`/`->toUpper`/`->toTitle` "Requires the
    // position of the character to be modified" — distinct from the
    // whole-string `->lowercase`/`->uppercase`/`->titlecase` already
    // implemented. "TEST"->toLower(1) only lowercases the 'T'.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        """
        [var('a' = 'TEST')][$a->(toLower: 1)][$a]|\
        [var('b' = 'test')][$b->(toUpper: 1)][$b]|\
        [var('c' = 'test')][$c->(toTitle: 3)][$c]
        """,
        context: &context
    )
    #expect(output == "tEST|Test|teSt")
}

@Test func stringUnescapeDecodesHexadecimalURLEncoding() async throws {
    // Ch. 25 Table 5: "Converts a string from the hexadecimal URL
    // encoding" — the documented inverse of `->encodeUrl`.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        "['A%20Short%20String'->(Unescape)]", context: &context
    )
    #expect(output == "A Short String")
}

@Test func stringCharacterInformationMemberTagsMatchTheLanguageGuidesOwnWorkedExampleOnTheLetterB() async throws {
    // Ch. 25 Table 11, the Guide's own worked example verbatim:
    // ['b'->(CharType: 1)] -> LOWERCASE_LETTER
    // ['b'->(IsLower: 1)] -> True
    // ['b'->(IsUpper: 1)] -> False
    // ['b'->(IsWhiteSpace: 1)] -> False
    // ['b'->(Digit: 1, 16)] -> 11
    // `->CharName` (the sibling line in the same worked example,
    // "LATIN SMALL LETTER B") is deliberately not implemented -- see
    // `StringOperations.swift`'s own doc comment -- so it's not
    // asserted here.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        """
        [(Array: 'b'->(CharType: 1), 'b'->(IsLower: 1), 'b'->(IsUpper: 1), \
        'b'->(IsWhiteSpace: 1), 'b'->(Digit: 1, 16))->join('|')]
        """,
        context: &context
    )
    #expect(output == "LOWERCASE_LETTER|true|false|false|11")
}

@Test func stringCharDigitValueAndGetNumericValueReturnMinusOneForANonDigitCharacter() async throws {
    // Ch. 25 Table 11: both return "-1" (worded as "if the character is
    // alphabetic", read against `->Digit`'s own sibling entry and
    // implemented via Swift's `wholeNumberValue`, nil for any
    // non-digit -- see `StringOperations.swift`'s own doc comment).
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        "[(Array: '5'->(CharDigitValue: 1), 'a'->(CharDigitValue: 1), 'a'->(GetNumericValue: 1))->join('|')]",
        context: &context
    )
    #expect(output == "5|-1|-1")
}

@Test func stringDigitCorrectlyRejectsACharacterThatIsNotAValidDigitInTheGivenRadix() async throws {
    // Regression test for a real bug found by architect review: an
    // earlier version only special-cased radix 16 and fell back to a
    // plain-decimal `wholeNumberValue` for every other radix, so
    // `Digit('5', 2)` returned 5 -- a value with no valid representation
    // in binary -- instead of the documented -1-for-invalid sentinel.
    // Decisive: '1' IS a valid binary digit (1), '5' is NOT (-1).
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        "[(Array: '1'->(Digit: 1, 2), '5'->(Digit: 1, 2))->join('|')]", context: &context
    )
    #expect(output == "1|-1")
}

@Test func stringGetNumericValueReturnsAFractionalValueForAVulgarFractionCharacterWhereCharDigitValueDoesNot() async throws {
    // Regression test for a real, previously-collapsed distinction found
    // by architect review: Ch. 25 Table 11 words `->GetNumericValue`
    // ("the DECIMAL value... or A NEGATIVE NUMBER") more broadly than
    // `->CharDigitValue` ("the INTEGER value... or -1"), matching ICU's
    // own documented split between `u_getNumericValue` (any Unicode
    // Numeric_Type, including fractions) and `u_charDigitValue`
    // (decimal digits only). U+00BD "½" has a real Unicode numeric
    // value (0.5) but is not a decimal digit -- decisive proof the two
    // tags now genuinely differ, unlike an earlier version that
    // collapsed both to the same `wholeNumberValue ?? -1`.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        "[(Array: '\u{00BD}'->(GetNumericValue: 1), '\u{00BD}'->(CharDigitValue: 1))->join('|')]",
        context: &context
    )
    #expect(output == "0.500000|-1")
}

@Test func stringIsalnumIsalphaIsdigitMemberTagsInspectASingleCharacterAtAPosition() async throws {
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        "[(Array: 'a1'->(IsAlnum: 1), 'a1'->(IsAlpha: 2), 'a1'->(IsDigit: 2), 'a1'->(IsDigit: 1))->join('|')]",
        context: &context
    )
    #expect(output == "true|false|true|false")
}

@Test func stringConcatenateFreeTagConcatenatesEveryParameter() async throws {
    // Ch. 25 Table 4, the Guide's own worked example:
    // [String_Concatenate: 'Test', ' string.'] -> Test string.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        "[String_Concatenate: 'Test', ' string.']", context: &context
    )
    #expect(output == "Test string.")
}

@Test func stringInsertFreeTagInsertsTextAtA1BasedPosition() async throws {
    // Ch. 25 Table 4: string, `-Text`, `-Position`. No worked example in
    // the Guide; hand-verified against its own prose -- inserting ' '
    // before position 2 of "AShortString" yields "A ShortString".
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        "[String_Insert: 'AShortString', -Text=' ', -Position=2]", context: &context
    )
    #expect(output == "A ShortString")
}

@Test func stringRemoveFreeTagUsesStartAndEndPositionMatchingTheLanguageGuidesOwnWorkedExample() async throws {
    // Ch. 25 Table 4/examples section, the Guide's own worked example
    // verbatim -- a DIFFERENT signature from the member `->Remove`
    // (offset+count): [String_Remove: 'A Short String', -StartPosition=3,
    // -EndPosition=8] -> A String.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        "[String_Remove: 'A Short String', -StartPosition=3, -EndPosition=8]", context: &context
    )
    #expect(output == "A String")
}

@Test func stringRemoveLeadingAndRemoveTrailingFreeTagsMatchTheLanguageGuidesOwnNestedWorkedExample() async throws {
    // Ch. 25 examples section, the Guide's own worked example verbatim
    // (nested calls): [String_RemoveLeading: -Pattern='*',
    //   (String_RemoveTrailing: -Pattern='*', '*A Short String*')]
    // -> A Short String
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        "[String_RemoveLeading: -Pattern='*', (String_RemoveTrailing: -Pattern='*', '*A Short String*')]",
        context: &context
    )
    #expect(output == "A Short String")
}

@Test func stringReplaceFreeTagReplacesOnlyTheFirstInstanceMatchingTheLanguageGuidesOwnWorkedExample() async throws {
    // Ch. 25 examples section, the Guide's own worked example verbatim:
    // [String_Replace: 'A Short String', -Find='Short', -Replace='Long']
    // -> A Long String. The free tag's own prose says "the FIRST
    // instance" -- deliberately narrower than the member `->Replace`
    // (every occurrence); a second, decisive assertion below proves
    // that distinction with a repeated find-term the single worked
    // example above can't discriminate.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        "[String_Replace: 'A Short String', -Find='Short', -Replace='Long']", context: &context
    )
    #expect(output == "A Long String")
    let repeated = try await LassoRenderer().render(
        "[String_Replace: 'a a a', -Find='a', -Replace='b']", context: &context
    )
    #expect(repeated == "b a a")
}

@Test func stringUpperCaseAndLowerCaseFreeTagsMatchTheLanguageGuidesOwnWorkedExample() async throws {
    // Ch. 25 examples section, the Guide's own worked example verbatim
    // (also proves the correct case direction against the chapter's
    // own self-contradictory Table 6 prose -- see the registration
    // site's own doc comment).
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        "[String_UpperCase: 'A Short String']|[String_LowerCase: 'A Short String']", context: &context
    )
    #expect(output == "A SHORT STRING|a short string")
}

@Test func stringExtractFreeTagMatchesTheLanguageGuidesOwnWorkedExampleUpToATrailingSpace() async throws {
    // Ch. 25 Table 10 examples section prints this worked example's
    // result as "Short" (no trailing space), but the SAME chapter's own
    // String_Remove worked example just above uses the IDENTICAL
    // -StartPosition=3/-EndPosition=8 pair against the SAME source
    // string and its result ("A String", verified by its own passing
    // test above) is only self-consistent if that range is INCLUSIVE of
    // position 8 -- position 8 is the space between "Short" and
    // "String", so String_Remove(3,8) removing "Short " (6 chars,
    // trailing space included) is what leaves "A" + "String" joined by
    // exactly one remaining space. Extract and Remove share near-
    // identical parameter wording with no documented distinction in
    // range semantics, so implemented to extract the exact same 6-
    // character range Remove deletes -- treating the Guide's printed
    // "Short" as a trailing-space lost in PDF rendering (an invisible,
    // easy-to-lose difference at the end of a line), not a genuine
    // exclusive-vs-inclusive divergence between two otherwise-identical
    // tag contracts.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        "[String_Extract: 'A Short String', -StartPosition=3, -EndPosition=8]", context: &context
    )
    #expect(output == "Short ")
}

@Test func stringFindPositionFreeTagReturns1BasedPositionOrZeroOnMiss() async throws {
    // Ch. 25 Table 10: string, `-Find` -> "the location of the -Find
    // parameter in the string parameter." No worked example in the
    // Guide; hand-verified: "Short" begins at position 3 of
    // "A Short String".
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        "[String_FindPosition: 'A Short String', -Find='Short']|[String_FindPosition: 'A Short String', -Find='zzz']",
        context: &context
    )
    #expect(output == "3|0")
}

@Test func stringFindBlocksFreeTagExtractsEverySubstringBetweenBeginAndEndDelimiters() async throws {
    // Ch. 25 Table 10: "The result is an array of strings contained
    // within the specified delimiters." No worked example exists
    // anywhere in the Guide for this tag (confirmed via direct search
    // of the whole document); implemented against its own prose only --
    // see the registration site's own doc comment.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        "[(String_FindBlocks: '<a>one</a><a>two</a>', -Begin='<a>', -End='</a>')->join(',')]",
        context: &context
    )
    #expect(output == "one,two")
}

@Test func stringFindBlocksFreeTagIgnoreCommentsSkipsWholeSourceLinesStartingWithTheCommentCharacter() async throws {
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        """
        [(String_FindBlocks: '<a>one</a>
        # <a>two</a>
        <a>three</a>', -Begin='<a>', -End='</a>', -IgnoreComments)->join(',')]
        """,
        context: &context
    )
    #expect(output == "one,three")
}

@Test func stringGetUnicodeVersionFreeTagReturnsANonEmptyVersionString() async throws {
    var context = LassoContext()
    let output = try await LassoRenderer().render("[String_GetUnicodeVersion]", context: &context)
    #expect(output.isEmpty == false)
}

@Test func stringFreeTagsWithDocumentedRequiredKeywordParametersThrowWhenOneIsOmitted() async throws {
    // Regression test for a real inconsistency found by code review:
    // `String_Insert`/`String_Remove`/`String_Replace`/`String_Extract`/
    // `String_FindBlocks` all document their keyword parameters as
    // required, but an earlier version silently no-op'd (returned the
    // unmodified input, an empty string, or an empty array) on an
    // OMITTED one instead of throwing — inconsistent with this file's
    // own `Encrypt_HMAC`/`File_ProcessUploads` precedent for exactly
    // this situation. Each assertion below omits exactly one required
    // keyword parameter.
    var context = LassoContext()
    let cases: [(String, String)] = [
        ("[protect][String_Insert('x', -Position=1)][/protect][error_currenterror]", "String_Insert requires -Text."),
        ("[protect][String_Insert('x', -Text='y')][/protect][error_currenterror]", "String_Insert requires -Position."),
        ("[protect][String_Remove('x', -EndPosition=1)][/protect][error_currenterror]", "String_Remove requires -StartPosition."),
        ("[protect][String_Remove('x', -StartPosition=1)][/protect][error_currenterror]", "String_Remove requires -EndPosition."),
        ("[protect][String_Replace('x', -Replace='y')][/protect][error_currenterror]", "String_Replace requires -Find."),
        ("[protect][String_Replace('x', -Find='x')][/protect][error_currenterror]", "String_Replace requires -Replace."),
        ("[protect][String_Extract('x', -EndPosition=1)][/protect][error_currenterror]", "String_Extract requires -StartPosition."),
        ("[protect][String_Extract('x', -StartPosition=1)][/protect][error_currenterror]", "String_Extract requires -EndPosition."),
        ("[protect][String_FindBlocks('x', -End='y')][/protect][error_currenterror]", "String_FindBlocks requires -Begin."),
        ("[protect][String_FindBlocks('x', -Begin='y')][/protect][error_currenterror]", "String_FindBlocks requires -End."),
    ]
    for (source, expectedMessage) in cases {
        let output = try await LassoRenderer().render(source, context: &context)
        #expect(output == expectedMessage)
    }
}

// MARK: - Captures Stage 1 (capture literal + non-closure invoke)

@Test func captureLiteralCanBeStoredAndInvokedViaTheInvokeMemberMethod() async throws {
    // Ch. "Captures": "Captures are executed by calling their `invoke`
    // method."
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        """
        [local('cap' = { return 'hello' })]\
        [#cap->invoke]
        """,
        context: &context
    )
    #expect(output == "hello")
}

@Test func captureLiteralCanBeInvokedViaTheShorthandCallSyntax() async throws {
    // Ch. "Captures": "`#cap() // Shorthand invocation`"
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        """
        [local('cap' = { return 'hello' })]\
        [#cap()]
        """,
        context: &context
    )
    #expect(output == "hello")
}

@Test func captureBodyThatFallsOffTheEndWithoutAReturnProducesVoid() async throws {
    // Regression test for a real gap found by code review: an earlier
    // version of this test used a body (`local('unused' = 1)`) that
    // produces no incidental rendered output either way, so it would
    // have passed even with a plausible bug that made non-auto-collect
    // captures also return their rendered body output as a string
    // (`invokeCapture`'s own `capture.autoCollect ? .string(output) :
    // .void` ternary, simplified to always take the `.string` branch).
    // A literal string with no `return` produces real, visible
    // incidental output that MUST be discarded (not returned) for a
    // plain, non-auto-collect capture — decisive.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        """
        [local('cap' = { 'leaked' })]\
        [#cap()]|after
        """,
        context: &context
    )
    #expect(output == "|after")
}

@Test func captureLiteralBindsPositionalArgumentsToNumberedLocals() async throws {
    // Ch. "Captures": "Parameters arrive via positional special locals":
    // `#1`, `#2`, etc.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        """
        [local('cap' = { return #1 + #2 })]\
        [#cap(2, 3)]
        """,
        context: &context
    )
    #expect(output == "5")
}

@Test func autoCollectCaptureLiteralConcatenatesItsOwnRenderedOutputAsItsReturnValue() async throws {
    // Ch. "Captures": "An auto-collect capture concatenates the result
    // of calling the `asString` method on every value produced inside
    // the capture when the capture is executed, and produces that
    // value."
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        """
        [local('cap' = {^ 'a' 'b' 'c' ^})]\
        [#cap()]
        """,
        context: &context
    )
    #expect(output == "abc")
}

@Test func nestedCaptureLiteralsAndStringLiteralsContainingBracesParseCorrectly() async throws {
    // The brace-balanced extraction (`ExpressionLexer.readCaptureBody`)
    // must correctly skip over a `}` inside a string literal and
    // correctly balance a capture literal nested inside another one --
    // both real risks flagged by this stage's own scoping pass. Real
    // newlines (not `;`) separate the two statements inside `outer`'s
    // own body -- this parser's statement boundaries are newline-
    // driven; `;` is skipped as lexer trivia, not treated as a
    // statement separator (matches every other multi-statement tag/
    // type-method body test in this file). `cap` uses an auto-collect
    // body with no explicit `return` -- Stage 2 (Captures): a capture
    // invoked directly at the SAME top-level sequence as its own
    // creation, whose body DOES `return`, correctly (per Ch. "Captures":
    // "exiting from the current home as well as itself") aborts the
    // rest of that same top-level render once invoked -- exactly like a
    // real `[Return]` at page scope. That's real, deliberate behavior,
    // just not what THIS test is about (parsing, not non-local control
    // flow), so it's avoided here by construction rather than worked
    // around. `outer`/`inner` still use explicit `return`, since
    // `inner`'s home is `outer`'s own ACTIVE invocation frame (created
    // while `outer` itself is executing, not at top level) -- so its
    // non-local unwind is fully absorbed by `outer`'s own invocation and
    // never reaches top level at all, a good real exercise of nested
    // non-local propagation resolving cleanly.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        """
        [local('cap' = {^ 'a}b' ^})]\
        [#cap()]|\
        [local('outer' = { local('inner' = { return 'nested' })
        return #inner->invoke })]\
        [#outer()]
        """,
        context: &context
    )
    #expect(output == "a}b|nested")
}

@Test func captureLiteralUsesLiveReferenceClosureSemanticsNotASnapshot() async throws {
    // Superseded by Stage 3 (Captures, see `Documentation
    // /captures-subsystem-plan.md` §4.2(a)): Stage 1 shipped a narrower
    // value-type SNAPSHOT of the enclosing scope's locals (this test used
    // to assert exactly that narrower behavior, expecting "first"). Real
    // Lasso's own documented semantics are live-reference -- Ch.
    // "Captures" §1.5: "it will have access to the surrounding local
    // variables where the capture was created even when the capture is
    // being executed in code that has a different scope" -- so a
    // re-assignment of `#x` AFTER the capture literal was created, but
    // BEFORE it's invoked, must be visible when the capture finally runs:
    // "second", not "first".
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        """
        [local('x' = 'first')]\
        [local('cap' = { return #x })]\
        [local('x' = 'second')]\
        [#cap()]
        """,
        context: &context
    )
    #expect(output == "second")
}

// MARK: - Captures Stage 3 (live-reference closure semantics)

@Test func theLanguageGuidesOwnCanonicalWorkedExampleForLiveReferenceClosures() async throws {
    // Ch. "Captures" §1.5's own load-bearing citation, verbatim: "Stored
    // captures can be executed at any point and the code contained
    // within will operate as if it had been executed in the context in
    // which it was created... it will have access to the surrounding
    // local variables where the capture was created even when the
    // capture is being executed in code that has a different scope."
    // `method1` declares `my_local` (no value), creates a capture closing
    // over it, THEN assigns 'Hello' to `my_local`, THEN hands the capture
    // to `method2` -- a COMPLETELY DIFFERENT method -- which invokes it
    // with ', world.'. The capture's own `#my_local->append(#1)`
    // (self-mutating `String->append`) must reach back into `method1`'s
    // own (already-assigned) `my_local` storage cell, so `method1`'s own
    // trailing `return #my_local` sees the mutation: "Hello, world."
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        """
        <?lassoscript
        define method1() => {
            local(my_local)
            local(my_cap) = {
                #my_local->append(#1)
            }
            #my_local = 'Hello'
            method2(#my_cap)
            return #my_local
        }
        define method2(cap) => {
            #cap(', world.')
        }
        ?>
        [method1]
        """,
        context: &context
    ).trimmingCharacters(in: .whitespacesAndNewlines)
    #expect(output == "Hello, world.")
}

@Test func aBareLocalDeclarationWithNoValueStillGetsARealStorageCellBeforeAssignment() async throws {
    // Found while implementing Stage 3: `local(name)` (no `=` value) was
    // previously a pure no-op READ (returns whatever's already there, or
    // `.null`) that never actually created a storage cell -- harmless
    // under Stage 1's snapshot semantics, but a real gap for live-
    // reference closures: if the capture literal below were evaluated
    // BEFORE `my_local`'s storage cell existed, it would capture a
    // dictionary with no "my_local" entry at all, and the LATER `#my_local
    // = 'Hello'` would create a BRAND NEW, entirely disconnected cell --
    // silently breaking the exact mechanism this stage exists to provide.
    // `LassoContext.ensureLocalExists`, wired into bare `local(name)`
    // declarations, fixes this. This test is deliberately narrower than
    // the Guide's own worked example above: it isolates JUST the bare-
    // declaration-creates-a-cell requirement, independent of `method1`/
    // `method2`'s own cross-method invocation shape.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        """
        [local('my_local')]\
        [local('cap' = { return #my_local })]\
        [local('my_local' = 'Hello')]\
        [#cap()]
        """,
        context: &context
    )
    #expect(output == "Hello")
}

@Test func aCapturesOwnNewlyCreatedLocalDoesNotLeakBackIntoTheCallersScope() async throws {
    // The other side of live-reference closures: sharing box REFERENCES
    // for names the creating scope already had must NOT be confused with
    // sharing the whole SCOPE going forward. A brand new local the
    // capture body itself declares (never present in the creating
    // scope's own locals at capture-literal-evaluation time) gets its own
    // fresh, capture-invocation-local cell -- `Evaluator.invokeCapture`'s
    // own `defer { context.replaceLocals(savedLocals) }` restores the
    // CALLER's own dictionary wholesale afterward, discarding it. If this
    // regressed (e.g. captures started sharing the live dictionary
    // object itself, not just individual box references), `#leaked`
    // would incorrectly read "leaked value" here instead of empty.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        """
        [local('cap' = { local('leaked' = 'leaked value') })]\
        [#cap()]\
        [string(#leaked)]
        """,
        context: &context
    )
    #expect(output == "")
}

@Test func twoInvocationsOfTheSameCaptureWithDifferentPositionalArgumentsDoNotInterfere() async throws {
    // `#1`/`#2`/... get a FRESH box per invocation
    // (`Evaluator.invokeCapture`'s `LassoLocalBox(argument.value)`, not a
    // mutation of whatever box previously occupied that slot) --
    // otherwise a capture that closes over an outer local AND reads its
    // own positional argument could have one invocation's `#1` leak into
    // a later invocation that didn't pass one, or two overlapping
    // invocations (impossible in this single-threaded evaluator, but
    // worth pinning down explicitly) could stomp on each other's
    // arguments. Auto-collect, no explicit `return` -- an explicit
    // `return` here would be a Stage 2 non-local exit whose home is THIS
    // top level (the capture is invoked directly where it was created),
    // which correctly aborts the rest of the page after the FIRST
    // invocation -- real, unrelated Stage 2 behavior this test isn't
    // about, sidestepped the same way Stage 2's own tests do.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        """
        [local('cap' = {^ #1 ^})]\
        [#cap('first')]\
        |\
        [#cap('second')]\
        |\
        [#cap()]
        """,
        context: &context
    )
    #expect(output == "first|second|")
}

@Test func capturesCreatedAcrossLoopIterationsAllShareTheirHomesSingleLocalsBagNotAPerIterationCopy() async throws {
    // Pinning test for a question raised by code review: does a capture
    // created and STORED (not invoked) during one loop iteration, then
    // invoked again after the loop finishes, see ITS OWN iteration's
    // value for a loop-bound variable (`loop_value`), or the value the
    // variable held by the time the loop ended? Checked directly against
    // lassoguide.com/language/captures.html, which settles this
    // explicitly: "A capture with a home will always take the following
    // environment values from its home: self, locals, params, and
    // current call name." -- a capture's `locals` come from its home as
    // ONE shared, mutable bag (there is no per-iteration/block-scope
    // concept anywhere in the docs), not a value frozen at the capture's
    // own creation moment. So EVERY capture created across every
    // iteration of a loop within the SAME home shares that home's SAME
    // `loop_value` storage cell -- invoking any of them after the loop
    // ends correctly reflects `loop_value`'s FINAL value, matching how
    // an ordinary repeated `#x = ...` reassignment works elsewhere in
    // that same scope. This is the CORRECT, doc-faithful behavior, not a
    // bug -- deliberately NOT "fixed" to give loop bodies their own
    // per-iteration scope, which real Lasso's own local-variable model
    // (this codebase's existing single-flat-dictionary-per-call-frame
    // design already matches it) simply doesn't have.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        """
        <?lassoscript
        define collectCaptures() => {
            local(caps) = array
            iterate(array('a', 'b', 'c'), local(item))
                #caps->insert({^ #item ^})
            /iterate
            local(results) = array
            iterate(#caps, local(cap))
                #results->insert(#cap->invoke)
            /iterate
            return #results->join('')
        }
        ?>
        [collectCaptures]
        """,
        context: &context
    ).trimmingCharacters(in: .whitespacesAndNewlines)
    #expect(output == "ccc")
}

@Test func typeConstructorsDoNotPermanentlyCorruptACallingScopesOwnLocalNamedParams() async throws {
    // Found by architect review: a real, capture-UNRELATED bug --
    // `Evaluator.instantiate`'s "legacy constructor params" shadowing
    // used to `context.set(...)` an ambient local named "params"
    // (Documentation/legacy-define-tag-type-plan.md's own "Constructor
    // params" note) and restore it afterward via `context
    // .replaceLocals(savedLocals)`. Stage 3's boxed locals broke this:
    // `set(...)` on an ALREADY-EXISTING name mutates that box in place
    // (exactly what makes closures work) -- so if the CALLING scope
    // already had its own local literally named "params" (a real,
    // plausible name -- it's the built-in pseudo-var for a method's own
    // arguments), the constructor call would silently overwrite that
    // box's value with its own constructor argument array, and
    // `replaceLocals` afterward would NOT undo it (same box object
    // either way -- restoring the name→box mapping doesn't restore a
    // mutated box's contents). No captures are involved in this
    // reproduction at all.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        """
        <?lassoscript
        define local_type => type {
            data i
            public onCreate(x) => { .i = #x }
        }
        define method1() => {
            local(params) = 'sentinel'
            local(obj) = local_type(42)
            return #params
        }
        ?>
        [method1]
        """,
        context: &context
    ).trimmingCharacters(in: .whitespacesAndNewlines)
    #expect(output == "sentinel")
}

@Test func associationOperatorFoldsACaptureLiteralAsATrailingArgumentOnABareIdentifierCall() async throws {
    // Real corpus shape (bugcity9/StartUpTags/AuthorizeNet_AIM_9.inc,
    // TS_lasso9/index.lasso): `someCall => { ... }` -- the general `=>`
    // path (NOT one of the six already-hardcoded keyword forms
    // if/while/loop/match/iterate/define), landing on a bare identifier
    // with no call syntax of its own, which must be promoted to a real
    // call so the capture has an argument slot to attach to. The tag
    // reads the associated block back via the real, documented
    // `givenBlock` keyword (Ch. "Captures") -- NOT a declared parameter
    // -- matching `foldAssociatedCapture`'s corrected design (labels the
    // capture "givenblock" and `Evaluator.extractGivenBlock` pulls it
    // out before ordinary parameter binding ever sees it; see that
    // function's own doc comment for the real bug this fixes). The
    // associated block auto-collects rather than using an explicit
    // `return` -- Stage 2 (Captures): `return`/`yield` inside a capture
    // also exits its home (Ch. "Captures"), so a capture whose body
    // returns AND whose value is meant to be used inline by the callee's
    // OWN wrapping `return(...)` is a materially different (and much
    // rarer) case than this test is actually about -- ordinary
    // `givenBlock->invoke(...)` threading a ready-made value back to its
    // caller, matching real corpus usage (`#AIMParams->forEachPair =>
    // {...}`, `inline(...)=>{records=>{...}}}`), none of which use an
    // explicit `return` inside the associated block at all.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        """
        [Define_Tag('UseWith')]\
            [return(givenBlock->invoke('hi'))]\
        [/Define_Tag]\
        [UseWith => {^ 'got: ' + #1 ^}]
        """,
        context: &context
    )
    #expect(output == "got: hi")
}

@Test func associationOperatorFoldsACaptureLiteralOntoABareMemberAccessWithNoExistingArguments() async throws {
    // Same mechanism as the free-tag case above, but folding onto
    // `.member(base, name, arguments: nil)` (a BARE property-style
    // member access, no parens at all) -- must be promoted to
    // `arguments: [captureArg]`, matching real corpus's
    // `#ary->forEachPair => {...}` shape (Stage 4's own eventual
    // `->forEach` work reuses this identical parse path; this test
    // exercises the parse+fold+invoke chain end-to-end using a plain
    // custom-type method instead, since `->forEach` itself isn't
    // implemented until Stage 4). `define`/`local` declaration
    // statements need `<?lassoscript ?>` script-mode wrapping to be
    // recognized at all (matching every other type-definition test in
    // this file, e.g. `typeDefinitionsConstructObjectsAndDispatchMethods`
    // just above) -- an ordinary bracket-tag `[...]` expects a single
    // VALUE expression, not a declaration/block statement.
    // Auto-collect associated block, no explicit `return` -- same reason
    // as `associationOperatorFoldsACaptureLiteralAsATrailingArgumentOnABareIdentifierCall`
    // just above.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        """
        <?lassoscript
        define widget => type {
            public usewith() => {
                return givenBlock->invoke('hi')
            }
        }
        local('w' = widget())
        ?>
        [#w->usewith => {^ 'got: ' + #1 ^}]
        """,
        context: &context
    ).trimmingCharacters(in: .whitespacesAndNewlines)
    #expect(output == "got: hi")
}

@Test func associationOperatorAppendsACaptureLiteralWithoutDisturbingExistingArguments() async throws {
    // Real corpus shape (TS_lasso9's `inline(-host=..., -sql=...)=>{...}`):
    // `=>` following a call that ALREADY has its own explicit `(...)`
    // argument list -- the associated block must not disturb the
    // existing argument's own binding. Auto-collect associated block, no
    // explicit `return` -- same reason as
    // `associationOperatorFoldsACaptureLiteralAsATrailingArgumentOnABareIdentifierCall`
    // above.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        """
        [Define_Tag('UseWith', -Required='First')]\
            [return(#First + ': ' + givenBlock->invoke('hi'))]\
        [/Define_Tag]\
        [UseWith('one') => {^ 'got: ' + #1 ^}]
        """,
        context: &context
    )
    #expect(output == "one: got: hi")
}

@Test func associationOperatorDoesNotCorruptATrailingOptionalParameterWhenFewerExplicitArgumentsAreGivenThanDeclared() async throws {
    // Regression test for the real bug architect review found in an
    // earlier version of `foldAssociatedCapture`: it appended the
    // capture as an ORDINARY UNLABELED positional argument, so a call
    // providing fewer explicit arguments than the callee declares
    // parameters for (relying on the trailing one being unbound/
    // defaulted, a completely normal shape) would have the capture
    // silently misbound into that later parameter's slot instead of
    // being kept separate -- e.g. `Wrap(5) => {...}` on a tag declaring
    // `-Required='Value', -Optional='Times'` would bind `#Times` to the
    // CAPTURE VALUE itself, not leave it unbound. Now that the capture
    // is threaded via `givenBlock` instead of ordinary positional
    // binding, `#Times` must still come through as its own genuinely
    // unbound (`.null`, empty string output) self, not the capture.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        """
        [Define_Tag('Wrap', -Required='Value', -Optional='Times')]\
            [return(string(#Value) + '|' + string(#Times))]\
        [/Define_Tag]\
        [Wrap(5) => { return 'unused' }]
        """,
        context: &context
    )
    #expect(output == "5|")
}

// MARK: - Captures Stage 2 (non-local return/yield, ->detach())

@Test func returnInsideACaptureExitsBothTheInvokeCallAndItsHomeMethodSkippingBothTrailingStatements() async throws {
    // Ch. "Captures": "Because captures are intended to execute as if
    // they had been invoked directly within their home, return and
    // yield will both behave by exiting from the current home as well
    // as itself." This is the Guide's own canonical shape: a capture
    // created inside one method (`method1`, its home) is handed to and
    // invoked from a DIFFERENT, more deeply nested method (`method2`) --
    // `return` inside the capture must unwind past `method2`'s own
    // trailing statement AND back out of `method1` itself, past ITS
    // trailing statement too, producing 'hello' as `method1`'s own
    // return value. NOTE: this interpreter always discards a called
    // tag/method's own internally-echoed bare-statement text (only its
    // explicit `return` value, or `.void`, ever crosses a call boundary
    // -- see `Evaluator.invokeCustomTag`'s `_ = try await
    // renderNodes(...)`) -- so "not reached"/"also not reached" would
    // never surface in `output` EITHER way, non-local or not. What
    // actually discriminates Stage 2 here is `method1`'s own RETURN
    // VALUE: under Stage 1's purely-local semantics `method1` would fall
    // off the end with no explicit return of its own and produce
    // `.void` (empty); Stage 2's non-local propagation instead makes
    // 'hello' surface all the way out as `method1`'s own return value.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        """
        <?lassoscript
        define method2(cap) => {
            #cap->invoke
            'not reached'
        }
        define method1() => {
            local(cap) = { return 'hello' }
            method2(#cap)
            'also not reached'
        }
        ?>
        [method1]
        """,
        context: &context
    ).trimmingCharacters(in: .whitespacesAndNewlines)
    #expect(output == "hello")
}

@Test func yieldBehavesLikeReturnForNonLocalExitButDoesNotResumeFromWhereItLeftOff() async throws {
    // Ch. "Captures": `yield`, like `return`, halts the capture and
    // exits its home non-locally -- exercised here via the SAME
    // method1/method2 shape as the test above, just with `yield`
    // instead of `return`. Also documents this stage's own explicitly
    // narrower scope (see `Captures.swift`'s doc comment): a SECOND
    // invocation of the same capture does NOT resume execution right
    // after the `yield` (real Lasso's own documented behavior) -- it
    // re-runs the body from the top and non-locally exits all over
    // again, rather than continuing past the `yield`.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        """
        <?lassoscript
        define method2(cap) => {
            #cap->invoke
            'not reached'
        }
        define method1() => {
            local(cap) = { yield 'hello' }
            method2(#cap)
            'also not reached'
        }
        ?>
        [method1]
        """,
        context: &context
    ).trimmingCharacters(in: .whitespacesAndNewlines)
    #expect(output == "hello")
}

@Test func nonLocalReturnFromACaptureInvokedThroughANestedCallSkipsSiblingStatementsAtTheHomeLevel() async throws {
    // Real-shape analogue of the Guide's own `contains()`/`forEach`
    // worked example (`->forEach` itself is Stage 4, not yet
    // implemented; this simulates the same "check each item, stop on
    // match" pattern via sequential `checkItem` calls instead of a
    // native `loop`/`iterate` block -- see the found-but-out-of-scope
    // bug noted just below). A capture created INSIDE `contains()`
    // itself is invoked from a nested `checkItem` call for each
    // candidate; `return true` on a match must unwind past `checkItem`'s
    // own call AND skip every SUBSEQUENT sibling statement in
    // `contains()`'s own body (the later `checkItem(#cap, 4)` calls and
    // the trailing `'no match'` fallback), producing `true` as
    // `contains()`'s own return value.
    //
    // Deliberately does NOT use `loop`/`iterate`/`while`/`with`/`records`
    // here: found, while designing this test, that NONE of those five
    // native block constructs check `shouldStopRenderingCurrentBody()`
    // between their own internal iterations (`RendererEngine
    // .renderBlock`, Renderer.swift) -- only the separate
    // `consumeLoopControlSignal()`/`Loop_Abort` mechanism halts them
    // early. This is a genuine, pre-existing gap (a bare `return` inside
    // e.g. `loop(-from=1,-to=5) => { if(...) => { return x } }`, with NO
    // capture involved at all, silently keeps iterating all 5 times
    // instead of stopping at the match) -- entirely independent of
    // Captures, unrelated to this stage's own scope, and left for
    // separate follow-up rather than fixed here.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        """
        <?lassoscript
        define checkItem(cap, value) => {
            #cap->invoke(#value)
        }
        define contains(needle) => {
            local(cap) = {
                if(#1 == #needle) => { return true }
            }
            checkItem(#cap, 1)
            checkItem(#cap, 2)
            checkItem(#cap, 3)
            checkItem(#cap, 4)
            'no match'
        }
        ?>
        [contains(3)]
        """,
        context: &context
    ).trimmingCharacters(in: .whitespacesAndNewlines)
    #expect(output == "true")
}

@Test func detachedCaptureReturnStaysPurelyLocalAndDoesNotExitItsFormerHome() async throws {
    // Ch. "Captures": "A capture can be detached from its home in order
    // to escape from this [non-local] behavior... detaches the capture
    // so that it no longer has a home capture." Same method1/method2
    // shape as the non-local tests above, but each method now has its
    // OWN trailing explicit `return` (rather than falling off the end)
    // so the difference is observable through the one channel that
    // survives a call boundary in this interpreter -- return VALUES, not
    // internally-echoed statement text (see the first test above's own
    // note). Non-detached, `method2`'s own trailing `return` would never
    // run (skipped by the still-propagating non-local signal) and
    // `method1` would receive 'hello' directly, exactly like the first
    // test above. Detached, `return 'hello'` inside the capture stops
    // being non-local at all -- `#cap->detach->invoke` produces 'hello'
    // as an perfectly ordinary LOCAL value, `method2`'s OWN trailing
    // `return` then runs normally afterward, and `method1` sees THAT
    // value, not the capture's.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        """
        <?lassoscript
        define method2(cap) => {
            #cap->detach->invoke
            return 'method2 finished'
        }
        define method1() => {
            local(cap) = { return 'hello' }
            local(result) = method2(#cap)
            return 'method1 got: ' + string(#result)
        }
        ?>
        [method1]
        """,
        context: &context
    ).trimmingCharacters(in: .whitespacesAndNewlines)
    #expect(output == "method1 got: method2 finished")
}

@Test func nestedCaptureCreatedInsideAHomedCaptureInheritsThatCapturesHomeNotItsOwnRawDepth() async throws {
    // Ch. "Captures": "A capture that is created within a capture that
    // does have a home will have its home set to its parent capture's
    // home. This means that nested captures will all have the same
    // home." Found by code review: using the raw current call-stack
    // depth for a capture literal evaluated WHILE ANOTHER capture's own
    // body is executing (rather than inheriting THAT capture's home
    // verbatim) silently catches the nested capture's non-local return
    // one frame too early -- invisible when the outer capture is
    // invoked immediately, in place (that shape can't distinguish
    // correct from buggy), but wrong the moment the outer capture is
    // invoked from a DIFFERENT depth than where it was created, exactly
    // as here: `cap` is created inside `outerHome`, but not invoked
    // until `invokeElsewhere` (one frame deeper) calls it. `inner`,
    // created while `cap`'s own body runs, must inherit `cap`'s home
    // (`outerHome`'s own frame) -- so `return 'from inner'` unwinds all
    // the way past `cap`, past `invokeElsewhere`'s own trailing
    // statement, AND past `outerHome`'s own trailing statement, landing
    // as `outerHome()`'s own return value.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        """
        <?lassoscript
        define invokeElsewhere(c) => {
            #c->invoke
            return 'invokeElsewhere fallback'
        }
        define outerHome() => {
            local(cap) = {
                local(inner) = { return 'from inner' }
                #inner->invoke
                return 'outer fallback'
            }
            invokeElsewhere(#cap)
            return 'outerHome fallback'
        }
        ?>
        [outerHome]
        """,
        context: &context
    ).trimmingCharacters(in: .whitespacesAndNewlines)
    #expect(output == "from inner")
}

@Test func aSecondCaptureInvokeInTheSameExpressionDoesNotReRunOrClobberAFirstStillPropagatingReturn() async throws {
    // Found by architect review: `shouldStopRenderingCurrentBody()` is
    // only ever polled between STATEMENTS, never mid-expression -- so
    // without a guard, a SECOND `#cap->invoke` appearing later in the
    // SAME expression as a first one whose `return` is still
    // propagating (hasn't reached its target yet) would silently run to
    // completion as if nothing were happening: re-executing the
    // capture's body a second time, and its own invocation boundary's
    // `clearReturnSignal()` (called right before rendering that second
    // body) would wipe out the first invocation's still-live signal
    // before `method1_helper`'s own statement-level poll ever saw it.
    //
    // `method1`'s own return value alone can't distinguish "ran once"
    // from "ran twice" here -- BOTH invocations return the same 'X', and
    // whichever one's signal ultimately survives to reach `method1`'s
    // own home produces the identical value either way (a genuinely
    // non-decisive shape, caught by tracing through what the buggy,
    // unguarded behavior would ALSO produce before finalizing this
    // test). `$checkedCount` is a GLOBAL-scope variable specifically
    // because it survives independently of the discarded local-scope/
    // return-value chain -- a real, observable side effect proving how
    // many times the capture's body actually executed, unaffected by
    // which invocation's propagating signal happens to win.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        """
        <?lassoscript
        var(checkedCount) = 0
        define method1_helper(cap) => {
            local(combined) = #cap->invoke + '-' + #cap->invoke
            return 'helper done: ' + #combined
        }
        define method1() => {
            local(cap) = {
                $checkedCount += 1
                return 'X'
            }
            method1_helper(#cap)
            return 'after'
        }
        ?>
        [method1]|[$checkedCount]
        """,
        context: &context
    ).trimmingCharacters(in: .whitespacesAndNewlines)
    #expect(output == "X|1")
}

@Test func twoSiblingCapturesWithDifferentHomesInTheSameExpressionEachExitTheirOwnHomeCorrectly() async throws {
    // Found by architect review: same mid-expression hazard as the test
    // above, but with two SIBLING captures that have DIFFERENT homes --
    // without the guard, the SECOND capture's own `clearReturnSignal()`
    // would silently overwrite the FIRST capture's still-propagating
    // signal (value AND target depth) with its own, so the WRONG home
    // (`method3`, not `method1`) would "catch" the return, and
    // `method1`'s own exit would be lost without a trace.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        """
        <?lassoscript
        define method2(capA, capB) => {
            local(combined) = #capA->invoke + '-' + #capB->invoke
            return 'after2: ' + #combined
        }
        define method3(capA) => {
            local(capB) = { return 'B' }
            method2(#capA, #capB)
            return 'after3'
        }
        define method1() => {
            local(capA) = { return 'A' }
            method3(#capA)
            return 'after1'
        }
        ?>
        [method1]
        """,
        context: &context
    ).trimmingCharacters(in: .whitespacesAndNewlines)
    #expect(output == "A")
}

@Test func detachReturnsTheCaptureItselfSoItChainsDirectlyIntoInvoke() async throws {
    // Ch. "Captures": "...and then returns itself" -- `->detach` must
    // hand back the SAME capture (not void, not a copy) so
    // `#cap->detach->invoke(...)` chains in one expression, matching
    // the test above's own usage.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        """
        [local('cap' = { return #1 + #2 })]\
        [#cap->detach->invoke(2, 3)]
        """,
        context: &context
    )
    #expect(output == "5")
}

// MARK: - Captures Stage 4 (->forEach)

@Test func theLanguageGuidesOwnContainsWorkedExampleUsingArrayForEach() async throws {
    // Ch. "Captures", verbatim (used there to illustrate non-local
    // return, but a real, working example of ->forEach in its own
    // right): `#a->forEach => { #val == #1 ? return true }` -- checked
    // directly against lassoguide.com/language/captures.html. Real
    // Lasso 9.3 does NOT document `->forEach` as its own directly-
    // callable array method (confirmed: no entry on operations
    // /collections.html or in genindex.html) -- it's the method NAME a
    // type must implement to conform to trait_queriable/trait_forEach
    // (Ch. "Query Expressions", "Making an Object Queriable"). Providing
    // it directly on the built-in collection types too is this
    // interpreter's own disclosed extension (see the plan doc's Stage 4
    // note), matching the DOCS' OWN worked example's assumption that it
    // just works this way.
    //
    // Uses the Guide's own bare ternary shorthand verbatim
    // (`#val == #1 ? return true`) -- a bare `return`/`yield` embedded as
    // a ternary's action clause (not the WHOLE statement) used to not
    // get `ScriptBodyParser.normalizeReturn`'s bare-return-to-real-call
    // rewrite (that rewrite only ever sees the ternary's FULL statement
    // text), silently mis-parsing the same way bare `yield` did before
    // Stage 2 fixed IT for the whole-statement case. Real, reproducible
    // with zero forEach/captures involved at all (`x == 1 ? return true`
    // alone) -- fixed via `ExpressionParser.parseTernaryAction` (see
    // `bareReturnAndYieldWorkAsATernaryActionClause` for the focused
    // regression test).
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        """
        <?lassoscript
        define contains(a, val) => {
            #a->forEach => { #val == #1 ? return true }
            return false
        }
        ?>
        [contains(array(1, 2, 3), 2)]|[contains(array(1, 2, 3), 9)]
        """,
        context: &context
    ).trimmingCharacters(in: .whitespacesAndNewlines)
    #expect(output == "true|false")
}

@Test func arrayForEachInvokesTheBlockOnceForEveryElementInOrder() async throws {
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        """
        <?lassoscript
        var(collected) = array
        array(10, 20, 30)->forEach => { $collected->insert(#1 * 2) }
        ?>
        [$collected->join(',')]
        """,
        context: &context
    ).trimmingCharacters(in: .whitespacesAndNewlines)
    #expect(output == "20,40,60")
}

@Test func mapForEachYieldsPairsInSortedKeyOrderMatchingLassoIteratorValuesOwnConvention() async throws {
    // Ch. "Query Expressions"'s own account of `forEach` never specifies
    // what a MAP source should yield -- this interpreter has an
    // existing, established convention for exactly this (`Pair(key,
    // value)`, sorted by key), already used by `->Iterator`/
    // `->ReverseIterator` (`LassoIteratorValue.build`, `Iterator.swift`)
    // -- not a separate documented `->forEachPair` method (real Lasso
    // 9.3 has no such method at all -- checked directly, "No Records
    // Found" on reference.lassosoft.com, absent from lassoguide.com's
    // search index). `->forEach` on a map reuses that SAME convention
    // rather than inventing a new one. NOTE, found by review: `iterate`/
    // `with` (`Renderer.swift`) do NOT follow this convention -- they
    // iterate a map's raw, hash-order Swift `Dictionary` directly with
    // no sorting, and `with` doesn't yield `Pair`s for a map source at
    // all (bare values only) -- a real, pre-existing, benign
    // inconsistency between constructs, not something this stage
    // introduces or needs to reconcile.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        """
        <?lassoscript
        var(collected) = array
        map('b' = 2, 'a' = 1, 'c' = 3)->forEach => { $collected->insert(#1->first + '=' + #1->second) }
        ?>
        [$collected->join(',')]
        """,
        context: &context
    ).trimmingCharacters(in: .whitespacesAndNewlines)
    #expect(output == "a=1,b=2,c=3")
}

@Test func forEachWorksOnListSetQueueStackTreeMapAndPriorityQueue() async throws {
    // One shared mechanism (`Evaluator.forEachElements(of:)`) serving
    // every collection type this interpreter implements -- TreeMap
    // yields Pairs (like Map), the rest yield plain values.
    //
    // Set/PriorityQueue built via `->insert` chains rather than bare
    // constructor positional args (`set(3, 4)`, `priorityqueue(2, 1)`)
    // -- found, independent of Captures/forEach entirely, that those
    // two constructors' bare positional-argument form silently builds
    // an EMPTY collection (confirmed: `string(set(3,4))` → "Set: ",
    // `string(priorityqueue(2,1))` → "PriorityQueue: ", both empty)
    // even though the identical shape works correctly for List/Queue/
    // Stack. A real, pre-existing, separate gap, flagged for its own
    // follow-up -- `->insert` chains are unaffected and confirmed
    // working correctly for both types.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        """
        <?lassoscript
        var(out) = array
        list(1, 2)->forEach => { $out->insert('list:' + #1) }
        local(s) = set
        #s->insert(3)
        #s->insert(4)
        #s->forEach => { $out->insert('set:' + #1) }
        queue(5, 6)->forEach => { $out->insert('queue:' + #1) }
        stack(7, 8)->forEach => { $out->insert('stack:' + #1) }
        local(pq) = priorityqueue
        #pq->insert(2)
        #pq->insert(1)
        #pq->forEach => { $out->insert('pq:' + #1) }
        treemap(1 = 'one', 2 = 'two')->forEach => { $out->insert('tree:' + #1->first + '=' + #1->second) }
        ?>
        [$out->join('|')]
        """,
        context: &context
    ).trimmingCharacters(in: .whitespacesAndNewlines)
    #expect(output == "list:1|list:2|set:3|set:4|queue:5|queue:6|stack:7|stack:8|pq:1|pq:2|tree:1=one|tree:2=two")
}

@Test func aCustomTypesOwnForEachMethodStillDispatchesCorrectlyNotInterceptedByTheBuiltInCase() async throws {
    // The new generic `(_, "foreach")` case in `Evaluator.member` must
    // NOT intercept a user-defined type's OWN `forEach` method --
    // `Evaluator.forEachElements(of:)` returns `nil` for any `.object`
    // whose `typeName` isn't one of the known built-in collection names,
    // correctly falling through to the pre-existing (Stage 1)
    // `invokeMemberMethod`/`givenBlock` dispatch this already used
    // before Stage 4 ever existed.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        """
        <?lassoscript
        define user_list => type {
            data items
            public onCreate() => { .items = array('a', 'b', 'c') }
            public forEach() => {
                local(gb) = givenBlock
                iterate(.items, local('i'))
                    #gb->invoke(#i)
                /iterate
            }
        }
        var(out) = ''
        user_list()->forEach => { $out->append(#1) }
        ?>
        [$out]
        """,
        context: &context
    ).trimmingCharacters(in: .whitespacesAndNewlines)
    #expect(output == "abc")
}

@Test func queueInsertFromInsertsAnotherCollectionsElementsMatchingTheDocumentedTraitForEachSignature() async throws {
    // Ch. 30 (operations/collections.html): "queue->insertFrom
    // (value::trait_forEach) — Inserts new elements into the queue...
    // by taking an object that implements trait_forEach." The ONE real,
    // documented `->insertFrom` in Lasso 9.3 (List/Set/Array only have
    // this under the legacy 8.x reference, a different iterator-based
    // mechanism this interpreter doesn't implement).
    //
    // Verifies via `string(...)` (Ch. 30's own documented auto-
    // stringification, "Queue: elem1, elem2, ...") rather than
    // `->join(',')` -- found, independent of Captures/InsertFrom
    // entirely, that `->join` is only registered for List (Table 5),
    // not Queue/Stack/Set/PriorityQueue at all; a real, pre-existing,
    // separate gap, flagged for its own follow-up.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        """
        [local('q' = queue(1, 2))]\
        [#q->insertFrom(array(3, 4))]\
        [string(#q)]
        """,
        context: &context
    )
    #expect(output == "Queue: 1, 2, 3, 4")
}

@Test func queueInsertFromUsedAsABareStatementWritesBackToTheReceiversOwnVariable() async throws {
    // `->insertFrom` is registered in `selfMutatingMethods` (Ch. 30
    // documents it as modifying the receiver) -- a bare top-level
    // statement use must persist the mutation back into `#q`, exactly
    // like `->Insert` already does for every other collection type.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        """
        [local('q' = queue(1, 2))]\
        [#q->insertFrom(array(3, 4))]|\
        [string(#q)]
        """,
        context: &context
    )
    #expect(output == "|Queue: 1, 2, 3, 4")
}

@Test func nonLocalReturnFromInsideArrayForEachCorrectlyAbortsRemainingElementsAndExitsToItsHome() async throws {
    // Stage 2's non-local-return mechanism must correctly interact with
    // Stage 4's new `->forEach` loop: `forEach` is NOT itself an
    // invocation boundary (no `pushTagCall` of its own, mirroring
    // `loop`/`iterate`) -- it must stop iterating the moment
    // `context.shouldStopRenderingCurrentBody()` goes true, and the
    // signal must keep propagating on up past `forEach`'s own call site
    // to its real home. `$checkedCount` (a GLOBAL, visible outside the
    // method) proves iteration genuinely stopped at the match -- NOT
    // merely that the right value came back, which could also happen if
    // `forEach` ran to completion and just happened to return the last
    // qualifying value.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        """
        <?lassoscript
        var(checkedCount) = 0
        define findFirstOver(a, threshold) => {
            #a->forEach => {
                $checkedCount += 1
                if(#1 > #threshold) => { return #1 }
            }
            return -1
        }
        ?>
        [findFirstOver(array(1, 2, 3, 4, 5), 2)]|[$checkedCount]
        """,
        context: &context
    ).trimmingCharacters(in: .whitespacesAndNewlines)
    #expect(output == "3|3")
}

// MARK: - Captures Stage 5 (String iteration family)

@Test func stringForEachCharacterInvokesTheBlockOncePerGraphemeCluster() async throws {
    // Ch. "String Operations" (operations/strings.html): "Executes a
    // given capture block once for every character in the base string.
    // The character can be accessed in the capture block through the
    // special local variable #1." Real, directly-callable String
    // method -- confirmed against lassoguide.com before implementing
    // (unlike Stage 4's collection `->forEach`, which isn't documented
    // as a built-in method at all).
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        """
        <?lassoscript
        var(collected) = array
        'abc'->forEachCharacter => { $collected->insert(#1) }
        ?>
        [$collected->join(',')]
        """,
        context: &context
    ).trimmingCharacters(in: .whitespacesAndNewlines)
    #expect(output == "a,b,c")
}

@Test func stringForEachWordBreakSplitsOnRealUnicodeWordBoundaries() async throws {
    // "Executes a given capture block once for every word in the base
    // string." The docs never define "word" further -- uses
    // Foundation's own ICU-backed `.byWords` segmentation (Unicode
    // UAX #29), matching this project's established "default to real
    // ICU/Unicode behavior when ambiguous" convention. Punctuation is
    // correctly excluded as its own token (not glued to the adjacent
    // word), proving this isn't a naive whitespace split.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        """
        <?lassoscript
        var(collected) = array
        'Hello, world!'->forEachWordBreak => { $collected->insert(#1) }
        ?>
        [$collected->join('|')]
        """,
        context: &context
    ).trimmingCharacters(in: .whitespacesAndNewlines)
    #expect(output == "Hello|world")
}

@Test func stringForEachLineBreakRecognizesAllThreeDocumentedLineBreakForms() async throws {
    // "Executes a given capture block once for every substring that
    // would be generated by splitting the base string on a line break.
    // Every line break character is recognized: \"\\r\", \"\\n\", and
    // \"\\r\\n\"." Foundation's `.byLines` enumeration already treats
    // \"\\r\\n\" as ONE break, not two -- verified here with a string
    // containing all three forms.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        """
        <?lassoscript
        var(collected) = array
        ('one\\rtwo\\nthree\\r\\nfour')->forEachLineBreak => { $collected->insert(#1) }
        ?>
        [$collected->join('|')]
        """,
        context: &context
    ).trimmingCharacters(in: .whitespacesAndNewlines)
    #expect(output == "one|two|three|four")
}

@Test func stringForEachMatchAcceptsABarePatternStringMatchingRealCorpusMatchRegexpConvention() async throws {
    // "string->forEachMatch(exp::string) — Executes a given capture
    // block once for every match in the base string. Matches can be
    // specified as either string or regexp objects." A bare string
    // argument is used directly as a regex pattern, matching
    // `Match_RegExp`'s own established convention.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        """
        <?lassoscript
        var(collected) = array
        'cat hat bat'->forEachMatch('[a-z]at') => { $collected->insert(#1) }
        ?>
        [$collected->join(',')]
        """,
        context: &context
    ).trimmingCharacters(in: .whitespacesAndNewlines)
    #expect(output == "cat,hat,bat")
}

@Test func stringForEachMatchAcceptsARealRegexpObjectArgument() async throws {
    // The documented second overload: "string->forEachMatch(exp::regexp)".
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        """
        <?lassoscript
        var(collected) = array
        'CAT hat BAT'->forEachMatch(regexp(-find='[a-z]+', -input='', -ignorecase=true)) => { $collected->insert(#1) }
        ?>
        [$collected->join(',')]
        """,
        context: &context
    ).trimmingCharacters(in: .whitespacesAndNewlines)
    #expect(output == "CAT,hat,BAT")
}

@Test func stringForEachMatchWithACapturingGroupInvokesOncePerMatchNotOncePerGroupFragment() async throws {
    // Found by code review: an earlier version built `forEachMatch`
    // directly on `LassoRegularExpressions.findAll`, which is Ch. 26
    // Table 11's `String_FindRegExp` helper -- a genuinely DIFFERENT,
    // incompatible documented contract ("a single FLAT array... full
    // match text followed by each capture group's text"). `forEachMatch`
    // itself documents ONE invocation per match, full-match text only
    // -- reusing `findAll` unmodified meant any pattern with a capture
    // group produced extra spurious invocations (the group text(s))
    // interleaved with the real per-match ones. Neither of the two
    // preceding `forEachMatch` tests catches this -- both use group-
    // free patterns -- which is exactly what let the bug ship in the
    // first place. Fixed via a new, dedicated
    // `LassoRegularExpressions.findAllWholeMatches` that never touches
    // `findAll`'s own flattened shape at all.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        """
        <?lassoscript
        var(collected) = array
        '12-34 56-78'->forEachMatch('(\\\\d+)-(\\\\d+)') => { $collected->insert(#1) }
        ?>
        [$collected->join(',')]
        """,
        context: &context
    ).trimmingCharacters(in: .whitespacesAndNewlines)
    #expect(output == "12-34,56-78")
}

@Test func stringForEachMatchEvaluatesItsPatternArgumentExactlyOnce() async throws {
    // Found by architect review: an earlier version evaluated the `exp`
    // argument twice -- once manually to extract the regex pattern,
    // once again (unconditionally, as part of the whole `arguments`
    // array) to build `invokeForEachCapture`'s own evaluated-argument
    // list. Harmless for a plain literal pattern, but a real bug the
    // moment `exp` is an arbitrary expression with a side effect --
    // this codebase otherwise carefully evaluates every argument
    // exactly once. `$sideEffects` proves `getPattern()` only actually
    // runs once.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        """
        <?lassoscript
        var(sideEffects) = 0
        define getPattern() => {
            $sideEffects += 1
            return '[a-z]+'
        }
        var(collected) = array
        'cat hat bat'->forEachMatch(getPattern()) => { $collected->insert(#1) }
        ?>
        [$collected->join(',')]|[$sideEffects]
        """,
        context: &context
    ).trimmingCharacters(in: .whitespacesAndNewlines)
    #expect(output == "cat,hat,bat|1")
}

@Test func stringForEachLineBreakHandlesTrailingLoneAndConsecutiveLineBreaksCorrectly() async throws {
    // Found by architect review as untested edge-case coverage (not a
    // bug -- Apple's own documented contract for the underlying
    // primitive, "carriage return, newline, or carriage return and
    // newline together," was independently confirmed correct): a
    // trailing line break, a string that IS just a line break, and
    // consecutive blank lines all need their own coverage beyond the
    // single "all three forms in the middle of content" case above.
    var context = LassoContext()
    let trailingOutput = try await LassoRenderer().render(
        """
        <?lassoscript
        var(collected) = array
        ('abc\\n')->forEachLineBreak => { $collected->insert(#1) }
        ?>
        [$collected->join('|')]
        """,
        context: &context
    ).trimmingCharacters(in: .whitespacesAndNewlines)
    #expect(trailingOutput == "abc")

    var context2 = LassoContext()
    let blankLineOutput = try await LassoRenderer().render(
        """
        <?lassoscript
        var(collected) = array
        ('a\\n\\nb')->forEachLineBreak => { $collected->insert(#1) }
        ?>
        [$collected->join('|')]
        """,
        context: &context2
    ).trimmingCharacters(in: .whitespacesAndNewlines)
    #expect(blankLineOutput == "a||b")

    // A string that IS just a line break produces one empty element,
    // not zero.
    var context3 = LassoContext()
    let countOutput = try await LassoRenderer().render(
        """
        <?lassoscript
        var(collected) = array
        ('\\n')->forEachLineBreak => { $collected->insert(#1) }
        ?>
        [$collected->size]
        """,
        context: &context3
    ).trimmingCharacters(in: .whitespacesAndNewlines)
    #expect(countOutput == "1")
}

@Test func stringForEachFamilySkipsRemainingMatchesOnNonLocalReturnMatchingStage2Semantics() async throws {
    // Same non-local-return interaction Stage 4 verified for collection
    // ->forEach -- `invokeForEachCapture` is shared code, but this
    // pins the behavior specifically for the NEW string call sites too
    // (`$checkedCount` proves genuine early exit, not a coincidence).
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        """
        <?lassoscript
        var(checkedCount) = 0
        define findFirstVowel(s) => {
            #s->forEachCharacter => {
                $checkedCount += 1
                if(#1 == 'a' or #1 == 'e' or #1 == 'i' or #1 == 'o' or #1 == 'u') => { return #1 }
            }
            return 'none'
        }
        ?>
        [findFirstVowel('xyzaeiou')]|[$checkedCount]
        """,
        context: &context
    ).trimmingCharacters(in: .whitespacesAndNewlines)
    #expect(output == "a|4")
}

// MARK: - Captures Stage 7 (currentCapture/givenBlock/restart/autoCollectBuffer)

@Test func currentCaptureIsVoidOutsideAnyCaptureInvocation() async throws {
    // Ch. "Captures", "Capture Methods": "currentCapture() -- Returns a
    // reference to the capture that is currently executing." This
    // codebase never materializes a `LassoCaptureValue` for a plain
    // page/method invocation (only for capture LITERALS), so calling it
    // with no capture actively invoked is a disclosed partial reading --
    // `.void`, not a real capture reference. `.void` renders as an empty
    // string when placed directly in an output block, matching this
    // codebase's established convention elsewhere for confirming
    // void-ness (`->type` is NOT used here -- `.void->type` deliberately
    // reads as a plain empty string per this codebase's own reviewed
    // "void degrades to string for member access" rule, so it answers
    // `"String"`, not `"void"`; unrelated to this stage).
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        "[currentCapture]",
        context: &context
    )
    #expect(output == "")
}

@Test func currentCaptureReturnsTheSameLiveObjectCurrentlyBeingInvoked() async throws {
    // Proves `currentCapture()` hands back the SAME live
    // `LassoCaptureValue` instance being invoked, not a copy or
    // placeholder: `cap->autoCollectBuffer` is set to a sentinel from
    // OUTSIDE, then `cap`'s own body reads `currentCapture-
    // >autoCollectBuffer` and returns it -- only identical if
    // `currentCapture` resolved to the literal same object `#cap` refers
    // to. (Deliberately sidesteps `->detach`/non-local-return timing:
    // `capture.homeDepth` is snapshotted onto `LassoContext
    // .captureHomeDepthStack` at the START of `invokeCapture`, before the
    // body runs, so a mid-body self-detach cannot retroactively affect
    // that SAME invocation's own return targeting -- a correct,
    // intentional consequence of the existing Stage 2 design, not
    // something to test around here.)
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        """
        [local('cap' = { return currentCapture->autoCollectBuffer })]\
        [#cap->autoCollectBuffer = 'sentinel']\
        [#cap->invoke]
        """,
        context: &context
    )
    #expect(output == "sentinel")
}

@Test func currentCaptureCorrectlyTracksTheInnermostActiveCaptureAcrossNestedInvocations() async throws {
    // Same identity proof as above, but confirms
    // `LassoContext.currentCaptureStack` correctly pushes to the INNER
    // capture while it's active and pops back to the OUTER one
    // afterward: `cap` reads its own `autoCollectBuffer` before and
    // after invoking a nested `inner` capture, which reads ITS OWN
    // (different) sentinel while active. If the stack leaked `inner`'s
    // identity into `cap`'s "after" reading (or vice versa), the
    // recorded sequence would show the wrong sentinel at the wrong
    // point.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        """
        <?lassoscript
        var(readings) = array
        local(inner) = { $readings->insert('inner:' + currentCapture->autoCollectBuffer) }
        local(cap) = {
            $readings->insert('before:' + currentCapture->autoCollectBuffer)
            #inner->invoke
            $readings->insert('after:' + currentCapture->autoCollectBuffer)
        }
        #cap->autoCollectBuffer = 'CAP'
        #inner->autoCollectBuffer = 'INNER'
        #cap->invoke
        ?>
        [$readings->join(',')]
        """,
        context: &context
    ).trimmingCharacters(in: .whitespacesAndNewlines)
    #expect(output == "before:CAP,inner:INNER,after:CAP")
}

@Test func captureGivenBlockMemberMethodIsVoidWhenNoAssociatedBlockWasGiven() async throws {
    // Ch. "Captures": "capture-> givenBlock ( ) -- Returns the capture
    // block associated with the current capture object, if any." `cap`
    // is invoked directly (`->invoke`, no `=>`), so it has no associated
    // block at all. `->detach` first (an already-proven Stage 2
    // mechanism) so this explicit `return` stays purely local instead of
    // aborting the rest of this render -- unrelated to what's actually
    // being tested here.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        """
        [local('cap' = { return currentCapture->givenBlock })]\
        [#cap->detach->invoke]
        """,
        context: &context
    )
    #expect(output == "")
}

@Test func captureGivenBlockMemberMethodReflectsTheBlockThatCaptureItselfWasInvokedWith() async throws {
    // Real bug found by architect review, fixed in the SAME commit as
    // this test: `#cap->invoke => {...}` reaches `Evaluator.invokeCapture`
    // with a `"givenblock"`-labeled argument (`foldAssociatedCapture` is
    // fully general -- ANY call/member expression followed by `=>`, not
    // `->forEach`-specific, per its own doc comment). Before the fix,
    // `invokeCapture` silently discarded that labeled argument instead
    // of pushing it onto `context.givenBlockStack` the way
    // `invokeCustomTag`/`invokeMemberMethod` already do -- so `cap`'s OWN
    // associated block was dropped, and `givenBlock`/`currentCapture->
    // givenBlock()` read from inside `cap`'s body would leak whatever
    // value an ENCLOSING tag/method call frame happened to have pushed,
    // or answer void with no such frame. `Evaluator.invokeCapture` now
    // calls the same `extractGivenBlock`/`pushGivenBlock`/`popGivenBlock`
    // sequence around its own body. `cap` is invoked with a DISTINCT
    // block of its own (`{^ 'mine' ^}`, not shared with anything else in
    // this test), so seeing its own value back proves the fix, not just
    // that SOME non-void capture reference was returned.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        """
        [local('cap' = { return currentCapture->givenBlock->invoke })]\
        [#cap->invoke => {^ 'mine' ^}]
        """,
        context: &context
    )
    #expect(output == "mine")
}

@Test func capturesOwnGivenBlockDoesNotLeakFromAnEnclosingTagsUnrelatedGivenBlock() async throws {
    // The other half of the same bug: a capture invoked with NO
    // associated block of its own, from WITHIN a custom tag that DOES
    // have one, must not see the ENCLOSING tag's given block as if it
    // were its own -- `currentCapture->givenBlock` should be void, not a
    // leaked, unrelated value. Directly reproduces the exact failure
    // mode the architect's review surfaced (a live probe against the
    // pre-fix code returned the outer tag's block here instead of void).
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        """
        [Define_Tag('Outer')]\
            [local('cap' = { return currentCapture->givenBlock })]\
            [return(#cap->invoke)]\
        [/Define_Tag]\
        [Outer => {^ 'outer' ^}]
        """,
        context: &context
    )
    #expect(output == "")
}

@Test func captureRestartReExecutesTheCaptureBodyFromTheTopLikeInvoke() async throws {
    // Ch. "Captures": "capture-> restart ( ) -- Resets the program
    // counter (PC) for the capture and begins executing the capture's
    // code again." This interpreter has no persistent PC to reset --
    // every invocation already restarts from the top (Stage 2's own
    // documented limitation) -- so `->restart()` and `->invoke()` are
    // behaviorally identical today; this pins that `->restart()` is a
    // real, callable method (not an unknown-method error) that fully
    // re-runs the body (observed via a mutated external counter) and
    // returns the freshly computed value. `->detach` first (unrelated to
    // what's being tested -- purely so the two explicit `return`s below
    // stay local instead of aborting the render after the first one).
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        """
        <?lassoscript
        var(count) = 0
        var(cap) = {
            $count += 1
            return $count
        }
        var(discard) = $cap->detach
        ?>
        [$cap->invoke]|[$cap->restart]|[$count]
        """,
        context: &context
    ).trimmingCharacters(in: .whitespacesAndNewlines)
    #expect(output == "1|2|2")
}

@Test func autoCollectBufferReflectsTheValueProducedByTheMostRecentPlainInvoke() async throws {
    // Ch. "Captures" worked example: "#distance(8, 2, 10, 5) // =>
    // 3.605551 #distance -> autoCollectBuffer // => 3.605551" -- a
    // SEPARATE, later read of `->autoCollectBuffer()` must see the same
    // value the capture's own invocation just produced.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        """
        [local('cap' = {^ 'a' 'b' 'c' ^})]\
        [#cap->invoke]|[#cap->autoCollectBuffer]
        """,
        context: &context
    )
    #expect(output == "abc|abc")
}

@Test func autoCollectBufferIsSettableAndReadableIndependentlyOfInvoke() async throws {
    // `capture-> autoCollectBuffer= ( value )` is listed as its own
    // distinct documented method alongside the getter -- a direct write
    // must be visible to a later read with no invocation in between.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        """
        [local('cap' = {^ 'x' ^})]\
        [#cap->autoCollectBuffer = 'preset']\
        [#cap->autoCollectBuffer]
        """,
        context: &context
    )
    #expect(output == "preset")
}

@Test func invokeAutoCollectComputesTheAutoCollectValueWithoutUpdatingTheStoredBuffer() async throws {
    // "Invokes the capture. If it is an auto-collect capture, this will
    // return the auto-collect value, but will NOT update
    // capture->autoCollectBuffer." Distinguishes this from a plain
    // `->invoke()`: the RETURN value must still be the freshly computed
    // auto-collect string, but a later `->autoCollectBuffer()` read must
    // still see whatever was there BEFORE this call (a sentinel set
    // explicitly, here), not the fresh value.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        """
        [local('cap' = {^ 'fresh' ^})]\
        [#cap->autoCollectBuffer = 'sentinel']\
        [#cap->invokeAutoCollect]|[#cap->autoCollectBuffer]
        """,
        context: &context
    )
    #expect(output == "fresh|sentinel")
}

@Test func autoCollectBufferStaysVoidForANonAutoCollectCaptureEvenAfterInvoke() async throws {
    // The buffer is specifically an auto-collect-capture concept (Ch.
    // "Captures": "If the capture is an auto-collect capture, this will
    // store..."/"...will set..."). A plain (non-`{^...^}`) capture's
    // `->invoke()` must never populate it. `->detach` first so the
    // explicit `return` inside `cap` stays local, matching the same
    // unrelated page-abort avoidance used by the other tests above.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        """
        [local('cap' = { return 'plain' })]\
        [#cap->detach->invoke]|[#cap->autoCollectBuffer]
        """,
        context: &context
    )
    #expect(output == "plain|")
}

// MARK: - Quoted/ticked string literal escape sequences

@Test func quotedStringSupportsTheFullDocumentedNamedControlCharacterEscapes() async throws {
    // Ch. "Literals" > "String Literals" > "Supported String Escape
    // Sequences" (lassoguide.com/language/literals.html) -- \a/\b/\e/\f/
    // \v joining the previously-implemented \n/\t/\r. An earlier cut of
    // this parser only recognized \n/\t/\r and silently dropped the
    // backslash for everything else (`\a` -> plain `a`), which this
    // fixes.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        "[bytes('\\a\\b\\e\\f\\v')->size]",
        context: &context
    )
    #expect(output == "5")
}

@Test func quotedStringEscapesForQuoteCharactersBackslashAndQuestionMark() async throws {
    // Same table: \" (0x22), \' (0x27), \? (0x3F), \\ (0x5C). \" and \'
    // already worked via the previous implementation's generic
    // "unrecognized escape keeps the following character" fallback
    // (coincidentally correct for exactly these four), so this pins that
    // behavior explicitly now that it's a real, deliberate table entry
    // rather than an accident of the old fallback.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        "['\\\"\\'\\?\\\\']",
        context: &context
    )
    #expect(output == "\"'?\\")
}

@Test func quotedStringHexUnicodeEscapesSupportOneToTwoDigits() async throws {
    // "\x dd Unicode character 1-2 hex digits". 0x41 = 'A'.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        "['\\x41']",
        context: &context
    )
    #expect(output == "A")
}

@Test func quotedStringUnicodeEscapesRequireExactlyFourOrEightHexDigits() async throws {
    // "\u dddd Unicode character 4 hex digits" / "\U dddddddd Unicode
    // character 8 hex digits" -- both 0x41 = 'A', zero-padded to the
    // documented, EXACT digit count (unlike \x's 1-2 digit range).
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        "['\\u0041' + '\\U00000041']",
        context: &context
    )
    #expect(output == "AA")
}

@Test func quotedStringOctalEscapesSupportOneToThreeDigits() async throws {
    // "\ ddd Unicode character 1-3 octal digits". Octal 101 = decimal 65
    // = 'A'.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        "['\\101']",
        context: &context
    )
    #expect(output == "A")
}

@Test func quotedStringBackslashEndOfLineRemovesTheLineBreakAndFollowingWhitespace() async throws {
    // The doc's own worked example, verbatim: "'This string \ had a
    // break in it' // => This string had a break in it" -- a backslash
    // immediately followed by an end-of-line removes that end-of-line
    // AND all following literal whitespace, resuming at the first
    // non-whitespace character.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        "['This string \\\n    had a break in it']",
        context: &context
    )
    #expect(output == "This string had a break in it")
}

@Test func quotedStringUnrecognizedEscapesPassThroughBothCharactersLiterallyNotJustTheSecondOne() async throws {
    // THE bug this whole investigation was filed for (during Captures
    // Stage 5): the documented escape table is closed/exhaustive with no
    // "anything else" clause, and the previous implementation's
    // undocumented fallback silently DROPPED the backslash for any
    // unrecognized escape (`\d` -> plain `d`) -- silently corrupting any
    // regex pattern shorthand (`\d`/`\w`/`\s`) written as a quoted
    // string. Now passes through literally instead (`\d` stays `\d`),
    // the safer, less-destructive reading given the docs don't specify
    // either way.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        "['(\\d+)-(\\w+)']",
        context: &context
    )
    #expect(output == "(\\d+)-(\\w+)")
}

@Test func quotedStringEscapesAreIdenticalForSingleAndDoubleQuoteDelimiters() async throws {
    // Ch. "Literals": "Lasso supports two kinds of string literals:
    // quoted and ticked" -- "quoted" covers BOTH single- and double-
    // quote delimiters with the SAME rules (confirmed directly against
    // the real docs, correcting an earlier misreading during Captures
    // Stage 5 that assumed single vs. double quotes had DIFFERENT escape
    // rules from each other -- the real distinction is quoted-vs-ticked,
    // an entirely separate axis, not quote-character-vs-quote-character).
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        "['\\x41\\n\\d']|[\"\\x41\\n\\d\"]",
        context: &context
    )
    #expect(output == "A\n\\d|A\n\\d")
}

@Test func tickedStringLiteralProducesItsRawContentWithNoEscapeProcessingAtAll() async throws {
    // Ch. "Literals" > "String Literals" > "Ticked Strings": "A ticked
    // string is a series of zero or more characters surrounded by a
    // pair of backticks... the backslash character holds no special
    // meaning." Entirely unimplemented before this fix -- a bare
    // backtick fell through to a stray `.symbol` token with no grammar
    // production, not a string literal at all. `\n` here must stay the
    // two literal characters backslash+n, NOT an actual newline.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        "[`a\\nb`]",
        context: &context
    )
    #expect(output == "a\\nb")
}

@Test func tickedStringLiteralCanContainQuoteCharactersAndBackslashesUnescaped() async throws {
    // The doc's own worked example, verbatim: "`A ticked string can
    // contain 'single quotes', "double quotes", \backslash characters\
    // and more - anything except backticks!`" -- exercising exactly
    // this, confirming quotes and backslashes need no special handling
    // inside a ticked string (real regex-pattern-friendly motivation the
    // doc itself states: "particularly useful when using regular
    // expressions which often require many backslashes").
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        "[`A ticked string can contain 'single quotes', \"double quotes\", \\backslash characters\\ and more - anything except backticks!`]",
        context: &context
    )
    #expect(output == "A ticked string can contain 'single quotes', \"double quotes\", \\backslash characters\\ and more - anything except backticks!")
}

@Test func tickedStringLiteralIsIdealForRegexPatternsWithMultipleBackslashEscapes() async throws {
    // The doc's own stated motivation for ticked strings: regex patterns
    // that would otherwise need doubled backslashes as a quoted string.
    // A real \d+-\d+ pattern, written as a ticked string, must reach the
    // regex engine completely unmangled -- pins the end-to-end behavior
    // this whole investigation exists to guarantee, using
    // ->forEachMatch (Captures Stage 5), this codebase's own already-
    // implemented regex matching, with the SAME pattern that previously
    // needed a doubled backslash as a quoted string
    // (stringForEachMatchWithACapturingGroupInvokesOncePerMatchNotOncePerGroupFragment).
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        """
        <?lassoscript
        var(collected) = array
        'order 123-456 shipped'->forEachMatch(`\\d+-\\d+`) => { $collected->insert(#1) }
        ?>
        [$collected->join(',')]
        """,
        context: &context
    ).trimmingCharacters(in: .whitespacesAndNewlines)
    #expect(output == "123-456")
}

@Test func tickedStringContainingAnUnescapedApostropheDoesNotDesyncABareIfConditionScan() async throws {
    // Real bug found by architect + code-reviewer review (both
    // independently): this codebase has several OTHER, separate,
    // pre-existing "find the matching close, quote-aware" raw-text
    // scanners besides `ExpressionParser`'s own token-level lexer —
    // `ScriptBodyParser.readBareConditionBeforeBraceBody`/
    // `readBareConditionBeforeSemicolon`/`readBalanced`/`readStatement`/
    // `readUntilKeyword`, `TypeBodyParser`'s equivalents, `LassoParser
    // .scanSquare`, and `ExpressionParser.readCaptureBody` itself — all
    // used to find statement/argument/bracket-tag boundaries BEFORE
    // tokenization. None of them recognized backtick as a quote
    // character when ticked strings were first added, so a ticked
    // string containing an ODD number of unescaped `'`/`"` characters
    // (perfectly legal — "can contain 'single quotes', "double quotes"
    // ... and more") desynced their own independent quote-tracking
    // state. Confirmed live: before this fix, `if(#x == `it's a test`)`
    // failed outright with `.unknownFunction("if")` because
    // `readBareConditionBeforeBraceBody` mistook the `'` inside `it's`
    // for entering ANOTHER quoted region, losing track of the real `)`.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        """
        <?lassoscript
        local(x) = `it's a test`
        if(#x == `it's a test`) => { 'MATCHED' }
        else => { 'NO MATCH' }
        ?>
        """,
        context: &context
    )
    #expect(output == "MATCHED")
}

@Test func tickedRegexPatternContainingACharacterClassBracketDoesNotTruncateItsEnclosingBracketTag() async throws {
    // The MOST exploitable instance of the same bug class (per
    // code-reviewer review): `LassoParser.scanSquare` -- which finds the
    // closing `]` of every `[...]` bracket-tag, the dominant Lasso 9
    // syntax -- has NO depth counter for `[`/`]` at all; it breaks on
    // the very FIRST unquoted `]` it sees. A ticked regex pattern
    // containing its own `]` (a character class, e.g. `[0-9]+` -- the
    // doc's own stated primary motivation for ticked strings existing at
    // all: "particularly useful when using regular expressions") would
    // have its OWN `]` mistaken for the bracket-tag's real close,
    // silently truncating everything after it and leaking raw Lasso
    // source as page text. Confirmed live: before this fix, this exact
    // source produced a truncated tag followed by literal leaked source
    // text in the page output instead of matching "123" and continuing
    // normally.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        """
        [local('collected') = array]\
        ['abc123'->forEachMatch(`[0-9]+`) => { #collected->insert(#1) }]\
        [#collected->join(',')]|[bytes('after')->size]
        """,
        context: &context
    )
    #expect(output == "123|5")
}

// MARK: - Captures Stage 8.1 (Query Expressions: core with/select/do)

@Test func querySelectComputesTheDocsOwnSquareExampleVerbatim() async throws {
    // Ch. "Query Expressions" worked example, verbatim: "with n in
    // array(1,2,3,4,5,6,7,8,9) select #n * #n // => 1, 4, 9, 16, 25, 36,
    // 49, 64, 81".
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        "[(with n in array(1, 2, 3, 4, 5, 6, 7, 8, 9) select #n * #n)->join(',')]",
        context: &context
    )
    #expect(output == "1,4,9,16,25,36,49,64,81")
}

@Test func queryExpressionsCanBeAssignedNestedAndUsedAsAnotherQuerysSource() async throws {
    // Ch. "Query Expressions" worked example, verbatim: a query
    // expression assigned to a local, then used as ANOTHER query
    // expression's own `with...in` source -- "query expressions can be
    // treated as objects... assigned to variables and used repeatedly."
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        """
        <?lassoscript
        local(qe) = with n in array(1, 2, 3, 4, 5, 6, 7, 8, 9) select #n * #n
        local(result) = with newN in #qe select #newN * #newN
        ?>
        [#result->join(',')]
        """,
        context: &context
    ).trimmingCharacters(in: .whitespacesAndNewlines)
    #expect(output == "1,16,81,256,625,1296,2401,4096,6561")
}

@Test func queryDoWithABareExpressionPayloadRunsOnceForEveryElementProducingNoResultValue() async throws {
    // Ch. "Query Expressions" worked example, verbatim (the bare-
    // expression `do` form -- "with n in #ary do #n->upperCase"). Real
    // bug found live while implementing this: a bare-expression `do`
    // payload occupies the SAME "statement root" position a real
    // top-level statement would, so a self-mutating value-type method
    // call (`->insert` on an `.array`) needs `Evaluator.evaluateStatement`'s
    // dedicated write-back check, not plain `evaluate(_:)` -- otherwise
    // the computed result is silently discarded instead of persisted,
    // exactly like calling a self-mutating method nested inside a larger
    // expression (not at statement root) already does elsewhere in this
    // codebase.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        """
        <?lassoscript
        local(ary) = array('the', 'quick', 'brown', 'fox', 'jumped', 'the', 'shark')
        var(collected) = array
        with n in #ary do $collected->insert(#n->upperCase)
        ?>
        [$collected->join(',')]
        """,
        context: &context
    ).trimmingCharacters(in: .whitespacesAndNewlines)
    #expect(output == "THE,QUICK,BROWN,FOX,JUMPED,THE,SHARK")
}

@Test func queryDoWithACaptureLiteralPayloadProducesTheIdenticalResultToTheBareExpressionForm() async throws {
    // Ch. "Query Expressions": "Both query expressions operate
    // identically" -- the doc's own side-by-side comparison of the bare-
    // expression and `{...}`-capture forms of `do`.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        """
        <?lassoscript
        local(ary) = array('the', 'quick', 'brown', 'fox', 'jumped', 'the', 'shark')
        var(collected) = array
        with n in #ary do { $collected->insert(#n->upperCase) }
        ?>
        [$collected->join(',')]
        """,
        context: &context
    ).trimmingCharacters(in: .whitespacesAndNewlines)
    #expect(output == "THE,QUICK,BROWN,FOX,JUMPED,THE,SHARK")
}

@Test func queryDoCaptureLiteralPayloadRemainsAttachedToTheSurroundingMethodContextForNonLocalReturn() async throws {
    // Ch. "Query Expressions": "The block of code given to a `do`
    // remains attached to the surrounding method context, such that one
    // could return or yield." A `return` inside the do-capture's own
    // body must exit the ENCLOSING method (skipping its own trailing
    // statement) and skip any remaining query-expression elements, not
    // just locally exit the capture -- the same non-local-return
    // discipline Stage 2/Stage 4's own `->forEach` already established.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        """
        [Define_Tag('FindFirstEven')]\
            [with n in array(1, 3, 5, 4, 7, 6) do { #n % 2 == 0 ? return #n }]\
            [return('none')]\
        [/Define_Tag]\
        [FindFirstEven]
        """,
        context: &context
    )
    #expect(output == "4")
}

@Test func queryExpressionCanBePassedDirectlyAsACallArgument() async throws {
    // Ch. "Query Expressions": "query expressions can be treated as
    // objects... and they can be passed as parameters."
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        "[(with n in array(1, 2, 3) select #n + 10)->join('-')]",
        context: &context
    )
    #expect(output == "11-12-13")
}

@Test func bareWithFollowedByAnIdentifierButNoInStillFallsBackToAnOrdinaryIdentifier() async throws {
    // Extends the pre-existing regression guard
    // (malformedWithFallsBackToOrdinaryCodeWithoutSwallowingNextStatement,
    // which covers `with = 5`) to the NEW speculative-parse path this
    // stage adds: `with n` with an identifier but no following `in` at
    // all must ALSO gracefully fall back to treating `with` as a plain
    // identifier, not corrupt the rest of the statement or crash.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        """
        <?lassoscript
        with n
        $after = 'reached'
        ?>
        [$after]
        """,
        context: &context
    ).trimmingCharacters(in: .whitespacesAndNewlines)
    #expect(output == "reached")
}

@Test func statementLevelWithInDoBraceBlockFormStillWorksUnchangedAlongsideTheNewExpressionForm() async throws {
    // The pre-existing STATEMENT-level `with NAME in EXPR do { body }`
    // block tag (`ScriptBodyParser.parseWithOpening`/`Renderer.swift`'s
    // own `case "with":`) is a separate, real-corpus-driven construct
    // this stage must not regress -- exercised here in the SAME source
    // as the new expression-level query-expression form, confirming
    // neither interferes with the other.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        """
        <?lassoscript
        var(fromBlockTag) = array
        with x in array(10, 20, 30) do {
            $fromBlockTag->insert(#x)
        }
        local(fromQueryExpr) = with n in array(1, 2, 3) select #n * 100
        ?>
        [$fromBlockTag->join(',')]|[#fromQueryExpr->join(',')]
        """,
        context: &context
    ).trimmingCharacters(in: .whitespacesAndNewlines)
    #expect(output == "10,20,30|100,200,300")
}

@Test func queryExpressionOverANonQueriableSourceThrowsRatherThanSilentlyProducingAnEmptyResult() async throws {
    // Real Lasso restricts the with-source to "any object whose type
    // supports the `trait_queriable` trait" -- a plain integer doesn't
    // conform, and (unlike a custom user-defined type implementing its
    // own `forEach` member -- supported since Stage 8.5, see
    // `Evaluator.materializeCustomQueriableElements`) has no `forEach`
    // method to fall back to either, so it correctly hits the same
    // "not queriable" rejection path a real non-queriable source always
    // has.
    var context = LassoContext()
    await #expect(throws: Error.self) {
        _ = try await LassoRenderer().render(
            "[(with n in 5 select #n)->join(',')]",
            context: &context
        )
    }
}

@Test func queryExpressionWithVariableScopesToOnlyTheQueryExpressionEvenWhenAnOuterLocalSharesItsName() async throws {
    // Real bug found by code-reviewer review: `LassoContext.set(_:for:
    // scope:)` mutates an EXISTING box in place when one already exists
    // for a name (Stage 3's own live-reference contract) -- an earlier
    // cut of `evaluateQueryExpression` called `context.set(...)` to bind
    // the with-variable, which (if the enclosing scope already had a
    // LOCAL of the same name) mutated that SAME shared box on every
    // iteration. The save/restore `defer` only undoes the DICTIONARY
    // MAPPING, not a box's own value, so the outer variable was left
    // holding the query expression's LAST iteration value instead of
    // being correctly restored -- a real, confirmed violation of Ch.
    // "Query Expressions"'s own documented scoping rule ("new variables
    // introduced by a query expression clause will not be available
    // outside of the query expression that introduces them"). Fixed by
    // explicitly inserting a fresh box for the with-variable into a copy
    // of the saved locals (mirroring how `invokeCapture`/
    // `invokeCustomTag`'s own parameter binding always uses fresh boxes,
    // never reusing whatever box a same-named outer local already had).
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        """
        <?lassoscript
        local(n) = 999
        local(result) = with n in array(1, 2, 3) select #n * 2
        ?>
        [#n]|[#result->join(',')]
        """,
        context: &context
    ).trimmingCharacters(in: .whitespacesAndNewlines)
    #expect(output == "999|2,4,6")
}

// MARK: - Captures Stage 8.2 (Query Expressions: where/let/skip/take operations)

@Test func queryWhereFiltersElementsComputingTheDocsOwnOddNumberExampleVerbatim() async throws {
    // Ch. "Query Expressions" worked example, verbatim: "with n in
    // array(0,1,2,...,9) where #n % 2 != 0 select #n // => 1, 3, 5, 7, 9".
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        "[(with n in array(0, 1, 2, 3, 4, 5, 6, 7, 8, 9) where #n % 2 != 0 select #n)->join(',')]",
        context: &context
    )
    #expect(output == "1,3,5,7,9")
}

@Test func multipleWhereOperationsCombineWithLogicalAndMatchingTheDocsOwnEquivalenceExamples() async throws {
    // Ch. "Query Expressions": "using multiple where operations is
    // essentially the same as combining the expressions using the
    // logical 'and' operator" -- the doc's own three-way comparison,
    // verbatim: two chained wheres and a single &&-combined where
    // produce the SAME result (1, 5, 7), while an ||-combined where
    // produces a DIFFERENT one (1, 2, 3, 4, 5, 7, 8, 9).
    var context = LassoContext()
    let chained = try await LassoRenderer().render(
        "[(with n in array(0, 1, 2, 3, 4, 5, 6, 7, 8, 9) where #n % 2 != 0 where #n % 3 != 0 select #n)->join(',')]",
        context: &context
    )
    var context2 = LassoContext()
    let anded = try await LassoRenderer().render(
        "[(with n in array(0, 1, 2, 3, 4, 5, 6, 7, 8, 9) where #n % 2 != 0 && #n % 3 != 0 select #n)->join(',')]",
        context: &context2
    )
    var context3 = LassoContext()
    let ored = try await LassoRenderer().render(
        "[(with n in array(0, 1, 2, 3, 4, 5, 6, 7, 8, 9) where #n % 2 != 0 || #n % 3 != 0 select #n)->join(',')]",
        context: &context3
    )
    #expect(chained == "1,5,7")
    #expect(anded == "1,5,7")
    #expect(ored == "1,2,3,4,5,7,8,9")
}

@Test func letIntroducesANewVariableComputingTheDocsOwnSquareExampleVerbatim() async throws {
    // Ch. "Query Expressions" worked example, verbatim: "with n in
    // array(0,1,...,9) let n2 = #n * #n select #n2 // => 0, 1, 4, 9, 16,
    // 25, 36, 49, 64, 81".
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        "[(with n in array(0, 1, 2, 3, 4, 5, 6, 7, 8, 9) let n2 = #n * #n select #n2)->join(',')]",
        context: &context
    )
    #expect(output == "0,1,4,9,16,25,36,49,64,81")
}

@Test func whereCanReferenceALetIntroducedVariableComputingTheDocsOwnCombinedExampleVerbatim() async throws {
    // Ch. "Query Expressions" worked example, verbatim: `let n2 = #n *
    // #n` followed by `where #n2 % 2 != 0` -- proves `where` can see a
    // variable a PRECEDING `let` introduced, matching the doc's own
    // stated "using both where and let together" framing.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        "[(with n in array(0, 1, 2, 3, 4, 5, 6, 7, 8, 9) let n2 = #n * #n where #n2 % 2 != 0 select #n2)->join(',')]",
        context: &context
    )
    #expect(output == "1,9,25,49,81")
}

@Test func skipDropsTheSpecifiedNumberOfLeadingElementsMatchingTheDocsOwnExampleVerbatim() async throws {
    // Ch. "Query Expressions" worked example, verbatim: "with n in
    // array(0,1,...,9) skip 5 select #n // => 5, 6, 7, 8, 9".
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        "[(with n in array(0, 1, 2, 3, 4, 5, 6, 7, 8, 9) skip 5 select #n)->join(',')]",
        context: &context
    )
    #expect(output == "5,6,7,8,9")
}

@Test func takeKeepsOnlyTheSpecifiedNumberOfLeadingElementsMatchingTheDocsOwnExampleVerbatim() async throws {
    // Ch. "Query Expressions" worked example, verbatim: "with n in
    // array(0,1,...,9) take 5 select #n // => 0, 1, 2, 3, 4".
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        "[(with n in array(0, 1, 2, 3, 4, 5, 6, 7, 8, 9) take 5 select #n)->join(',')]",
        context: &context
    )
    #expect(output == "0,1,2,3,4")
}

@Test func skipAndTakeAreASequentialPipelineWhereRelativeOrderChangesTheResult() async throws {
    // Ch. "Query Expressions": "the order in which skip and take are
    // specified is significant" -- the doc's own three-way worked
    // example, verbatim: `skip 3 take 4` => 3,4,5,6 (skip first, THEN
    // take 4 of what remains); `take 4 skip 3` => 3 (take 4 first,
    // leaving 0,1,2,3, THEN skip 3 of THOSE, leaving just 3); a third
    // snippet using `skip 3 take 1` also => 3, confirming both readings
    // converge on the same single element by different means. Directly
    // exercises that this is a genuine sequential pipeline over the
    // surviving row list, not two independent, order-blind filters.
    var context = LassoContext()
    let skipThenTake = try await LassoRenderer().render(
        "[(with n in array(0, 1, 2, 3, 4, 5, 6, 7, 8, 9) skip 3 take 4 select #n)->join(',')]",
        context: &context
    )
    var context2 = LassoContext()
    let takeThenSkip = try await LassoRenderer().render(
        "[(with n in array(0, 1, 2, 3, 4, 5, 6, 7, 8, 9) take 4 skip 3 select #n)->join(',')]",
        context: &context2
    )
    var context3 = LassoContext()
    let skipThenTakeOne = try await LassoRenderer().render(
        "[(with n in array(0, 1, 2, 3, 4, 5, 6, 7, 8, 9) skip 3 take 1 select #n)->join(',')]",
        context: &context3
    )
    #expect(skipThenTake == "3,4,5,6")
    #expect(takeThenSkip == "3")
    #expect(skipThenTakeOne == "3")
}

@Test func queryOperationsWorkCorrectlyWithTheDoActionAndNonMutatingBarePayloads() async throws {
    // Confirms operations (Stage 8.2) correctly compose with the `do`
    // action (Stage 8.1) -- a where-filtered, let-transformed row set
    // feeding a bare-expression do payload that collects into an
    // external array via a self-mutating write-back (the exact mechanism
    // Stage 8.1's own regression test already covers for the plain,
    // no-operations case).
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        """
        <?lassoscript
        var(collected) = array
        with n in array(0, 1, 2, 3, 4, 5, 6, 7, 8, 9) let doubled = #n * 2 where #doubled > 10 do $collected->insert(#doubled)
        ?>
        [$collected->join(',')]
        """,
        context: &context
    ).trimmingCharacters(in: .whitespacesAndNewlines)
    #expect(output == "12,14,16,18")
}

@Test func letIntroducedVariablesDoNotLeakOutsideTheQueryExpressionEvenWhenTheyShadowAnOuterLocal() async throws {
    // Same scoping guarantee already proven for the with-variable itself
    // (queryExpressionWithVariableScopesToOnlyTheQueryExpressionEvenWhenAnOuterLocalSharesItsName)
    // now extended to a `let`-introduced name: Ch. "Query Expressions":
    // "variables introduced with a let operation have the SAME SCOPE as
    // those introduced in a with clause. That is, they only exist within
    // the query expression."
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        """
        <?lassoscript
        local(n2) = 999
        local(result) = with n in array(1, 2, 3) let n2 = #n * #n select #n2
        ?>
        [#n2]|[#result->join(',')]
        """,
        context: &context
    ).trimmingCharacters(in: .whitespacesAndNewlines)
    #expect(output == "999|1,4,9")
}

// MARK: - Captures Stage 8.3 (Query Expressions: order by operation, sum/average/min/max actions)

@Test func orderByAscendingIsTheDefaultDirectionMatchingTheDocsOwnExampleVerbatim() async throws {
    // Ch. "Query Expressions" worked example, verbatim: "with n in
    // array(9,2,1,3,5,4,6,7,0,8) order by #n select #n // => 0, 1, 2, 3,
    // 4, 5, 6, 7, 8, 9".
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        "[(with n in array(9, 2, 1, 3, 5, 4, 6, 7, 0, 8) order by #n select #n)->join(',')]",
        context: &context
    )
    #expect(output == "0,1,2,3,4,5,6,7,8,9")
}

@Test func orderByDescendingReversesTheOrderMatchingTheDocsOwnExampleVerbatim() async throws {
    // Ch. "Query Expressions" worked example, verbatim: same array,
    // "order by #n descending select #n // => 9, 8, 7, 6, 5, 4, 3, 2, 1,
    // 0".
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        "[(with n in array(9, 2, 1, 3, 5, 4, 6, 7, 0, 8) order by #n descending select #n)->join(',')]",
        context: &context
    )
    #expect(output == "9,8,7,6,5,4,3,2,1,0")
}

@Test func orderByAcceptsAnArbitraryExpressionMatchingTheDocsOwnStringSizeExampleVerbatim() async throws {
    // Ch. "Query Expressions": "the expression provided to an order by
    // can be any arbitrary expression" -- the doc's own worked example,
    // verbatim: ordering a series of strings by their LENGTH (`#n->
    // size`), not the strings themselves. => the, fox, the, quick,
    // brown, shark, jumped.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        """
        [(with n in array('the', 'quick', 'brown', 'fox', 'jumped', 'the', 'shark') order by #n->size select #n)->join(',')]
        """,
        context: &context
    )
    #expect(output == "the,fox,the,quick,brown,shark,jumped")
}

@Test func orderByWithMultipleKeysSortsByThePrimaryKeyThenBreaksTiesWithTheSecondaryKey() async throws {
    // Ch. "Query Expressions" worked example, verbatim (the doc's own
    // "order the elements in an alphabetical manner" user-list example):
    // `order by #n->second, #n->first` -- sorts primarily by surname
    // (`second`), and for the two surnames that tie (both
    // "Hammershaimb"), breaks the tie using the given name (`first`).
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        """
        [(with n in array('Krinn'='Jones', 'Ármarinn'='Hammershaimb', 'Kjarni'='Jones', 'Halbjörg'='Skywalker', 'Björg'='Riley', 'Hjörtur'='Hammershaimb') order by #n->second, #n->first select #n)->join(', ')]
        """,
        context: &context
    )
    #expect(output == "(Hjörtur)=(Hammershaimb), (Ármarinn)=(Hammershaimb), (Kjarni)=(Jones), (Krinn)=(Jones), (Björg)=(Riley), (Halbjörg)=(Skywalker)")
}

@Test func orderByComposesCorrectlyWithWhereAndTakeInTheSamePipeline() async throws {
    // Confirms `order by` (Stage 8.3) correctly composes with earlier
    // operations (Stage 8.2) in the SAME sequential pipeline -- filters
    // odd numbers, sorts them descending, then takes only the top 3.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        "[(with n in array(0, 1, 2, 3, 4, 5, 6, 7, 8, 9) where #n % 2 != 0 order by #n descending take 3 select #n)->join(',')]",
        context: &context
    )
    #expect(output == "9,7,5")
}

@Test func sumAddsEveryElementTogetherMatchingTheDocsOwnExampleVerbatim() async throws {
    // Ch. "Query Expressions" worked example, verbatim: "with n in
    // array(1,2,...,9) sum #n // => 45".
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        "[with n in array(1, 2, 3, 4, 5, 6, 7, 8, 9) sum #n]",
        context: &context
    )
    #expect(output == "45")
}

@Test func averageComputesTheMeanMatchingTheDocsOwnExampleVerbatim() async throws {
    // Ch. "Query Expressions" worked example, verbatim: "with n in
    // array(1,2,...,9) average #n // => 5".
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        "[with n in array(1, 2, 3, 4, 5, 6, 7, 8, 9) average #n]",
        context: &context
    )
    #expect(output == "5")
}

@Test func minAndMaxProduceTheSmallestAndLargestElementsMatchingTheDocsOwnExamplesVerbatim() async throws {
    // Ch. "Query Expressions" worked examples, verbatim: "with n in
    // array(1,2,...,9) min #n // => 1" / "... max #n // => 9".
    var context = LassoContext()
    let min = try await LassoRenderer().render(
        "[with n in array(1, 2, 3, 4, 5, 6, 7, 8, 9) min #n]",
        context: &context
    )
    var context2 = LassoContext()
    let max = try await LassoRenderer().render(
        "[with n in array(1, 2, 3, 4, 5, 6, 7, 8, 9) max #n]",
        context: &context2
    )
    #expect(min == "1")
    #expect(max == "9")
}

@Test func aggregateActionsOnAnEmptyResultSetProduceVoidRatherThanAnArbitraryNumericDefault() async throws {
    // No worked example in the real docs covers an empty result set for
    // any of sum/average/min/max. Disclosed choice: all four produce
    // void (renders as an empty string) rather than assuming an
    // arbitrary numeric identity (e.g. 0 for sum) -- consistent with
    // this codebase's own established Array->First-on-empty convention,
    // and avoids a divide-by-zero for average specifically.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        "[with n in array() sum #n]|[with n in array() average #n]|[with n in array() min #n]|[with n in array() max #n]",
        context: &context
    )
    #expect(output == "|||")
}

// MARK: - Captures Stage 8.4 (Query Expressions: group by operation, queriable_grouping type)

@Test func groupByBucketsRowsSharingAnEqualKeyAndPreservesEachGroupsElements() async throws {
    // Ch. "Query Expressions", "Group By": "a group by operation permits
    // similar elements to be grouped together by a particular key
    // expression". Verifies grouping CORRECTNESS directly -- one group
    // per distinct key, in first-occurrence order, each retaining
    // exactly its own original elements -- rather than a fragile string
    // match against a `queriable_grouping`'s own (undocumented, and
    // therefore deliberately unspecified -- see `Runtime.swift`'s own
    // "no documented bare-output contract" policy) auto-string format.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        """
        [(with n in array('a'=1, 'a'=2, 'b'=3, 'a'=4, 'b'=5)
            group #n->second by #n->first into g
            select #g->key + ':' + (with x in #g select #x)->join('-'))->join(',')]
        """,
        context: &context
    )
    #expect(output == "a:1-2-4,b:3-5")
}

@Test func groupByMatchesTheDocsOwnWorkedExampleGroupMembershipVerbatim() async throws {
    // Ch. "Query Expressions", "Group By" worked example, verbatim data
    // and pipeline (swap first/last name into a Pair, group by original
    // surname, sort resulting groups by key). The doc's own "expected
    // output" for this example is informal narrative prose ("Line
    // breaks added for readability"), not a verified literal runtime
    // transcript, so this checks the same GROUPING the doc's prose
    // describes -- which given names ended up in which surname's group,
    // and in what sorted-by-key order the groups themselves come out --
    // via `->key` and a nested `with` over each `queriable_grouping`,
    // rather than trusting the prose's own formatting.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        """
        [(with n in array('Jones'='Krinn', 'Hammershaimb'='Ármarinn', 'Jones'='Kjarni', 'Skywalker'='Halbjörg', 'Riley'='Björg', 'Hammershaimb'='Hjörtur')
            let swapped = pair(#n->second, #n->first)
            group #swapped by #n->first into g
            let key = #g->key
            order by #key
            select #key + ': ' + (with x in #g select #x->first)->join(','))->join(' | ')]
        """,
        context: &context
    )
    #expect(output == "Hammershaimb: Ármarinn,Hjörtur | Jones: Krinn,Kjarni | Riley: Björg | Skywalker: Halbjörg")
}

@Test func queriableGroupingIsItselfQueriableAsANestedWithSource() async throws {
    // Ch. "Query Expressions", "Group By": "This new object can be
    // further used throughout the query expression" -- a
    // `queriable_grouping` supports `trait_queriable` just like an
    // array or list, exercising the new `forEachElements(of:)` case
    // (Stage 8.4) added alongside List/Set/Queue's own (Stage 4).
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        """
        [with n in array('a'=1, 'a'=2, 'b'=3)
            group #n->second by #n->first into g
            select (with x in #g where #x > 1 select #x)->join(',')]
        """,
        context: &context
    )
    #expect(output == "23")
}

@Test func groupByKeyIsAccessibleButOnlyTheNewVariableCarriesForwardIntoLaterOperations() async throws {
    // Ch. "Query Expressions", "Group By": "From this point forward, no
    // previously introduced variables are available. Only [the new
    // name] exists now." Confirms the CORE, observable behavior: after
    // `group ... into g`, a later `order by`/`select` sees rows keyed
    // ONLY by `g` -- ordering by `#g->key` (not the original `#n`, which
    // no longer has a live per-row binding) still works correctly.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        """
        [(with n in array('b'=1, 'a'=2, 'b'=3)
            group #n->second by #n->first into g
            order by #g->key
            select #g->key)->join(',')]
        """,
        context: &context
    )
    #expect(output == "a,b")
}

// MARK: - Captures Stage 8.5 (Query Expressions: multiple with clauses, generateSeries, Making an Object Queriable)

@Test func multipleWithClausesNestIterationsAndTheCommaFormMatchesTheDocsOwnEquivalenceClaim() async throws {
    // Ch. "Query Expressions", "The With Clause": "Multiple subsequent
    // with clauses can follow the first. When this occurs, the second
    // `with` word can optionally be replaced by a comma... Multiple with
    // clauses define a nesting of iterations. The following two example
    // snippets are equivalent: `with variable_name in source with
    // another_name in #variable_name` / `with variable_name in source,
    // another_name in #variable_name`." No concrete worked EXAMPLE with
    // actual values is given for this specific claim, so this verifies
    // the documented CROSS-PRODUCT nesting behavior directly (each outer
    // element paired with every inner element, in order) and confirms
    // both spellings produce the IDENTICAL result, per the docs' own
    // equivalence claim.
    var context = LassoContext()
    let commaForm = try await LassoRenderer().render(
        "[(with a in array(1, 2), b in array('x', 'y') select #a + #b)->join(',')]",
        context: &context
    )
    var context2 = LassoContext()
    let withKeywordForm = try await LassoRenderer().render(
        "[(with a in array(1, 2) with b in array('x', 'y') select #a + #b)->join(',')]",
        context: &context2
    )
    #expect(commaForm == "1x,1y,2x,2y")
    #expect(withKeywordForm == commaForm)
}

@Test func laterWithClausesCanReferenceAnEarlierClausesVariable() async throws {
    // "Multiple with clauses define a nesting of iterations" — the
    // SECOND clause's own source expression (`array('a', 'b', 'c')`
    // here, standing in for the docs' own "digging into nested
    // sequences" framing) is evaluated freshly for EVERY outer row, with
    // the outer variable already bound and readable via `#outer`.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        "[(with outer in array(1, 2), inner in array('a', 'b', 'c') select #outer + ':' + #inner)->join(',')]",
        context: &context
    )
    #expect(output == "1:a,1:b,1:c,2:a,2:b,2:c")
}

@Test func multipleWithClausesComposeCorrectlyWithAWhereOperation() async throws {
    // Confirms the new multi-clause row-fanout (Stage 8.5) feeds
    // correctly into the PRE-EXISTING operations pipeline (Stage 8.2) —
    // `where` filters the already-cross-joined row set, not just the
    // first clause's own elements.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        "[(with a in array(1, 2), b in array(10, 20) where #a + #b > 15 select #a + '+' + #b)->join(',')]",
        context: &context
    )
    #expect(output == "1+20,2+20")
}

@Test func generateSeriesFunctionAndLiteralFormsAreEquivalentMatchingTheDocsOwnSumExample() async throws {
    // Ch. "Query Expressions", "GenerateSeries Type" worked example,
    // verbatim: "with num in generateSeries(2, 11, 2) sum #num // => 30"
    // — note 11 is NOT part of the generated series (2, 4, 6, 8, 10).
    // "There is also a generateSeries literal syntax... with num in 2 to
    // 11 by 2 sum #num // => 30" — the docs' own claimed equivalence,
    // verified directly against the SAME result.
    var context = LassoContext()
    let functionForm = try await LassoRenderer().render(
        "[with num in generateSeries(2, 11, 2) sum #num]",
        context: &context
    )
    var context2 = LassoContext()
    let literalForm = try await LassoRenderer().render(
        "[with num in 2 to 11 by 2 sum #num]",
        context: &context2
    )
    #expect(functionForm == "30")
    #expect(literalForm == "30")
}

@Test func generateSeriesLiteralFormDefaultsToAStepOfOneWhenByIsOmitted() async throws {
    // "an optional third parameter can specify the step to use for
    // going through the series, defaulting to 1" — the `to`-only
    // literal form (no trailing `by`) should default identically.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        "[(with num in 1 to 5 select #num)->join(',')]",
        context: &context
    )
    #expect(output == "1,2,3,4,5")
}

@Test func generateSeriesAsStaticArrayMatchesTheDocsOwnExampleVerbatim() async throws {
    // Ch. "Query Expressions" worked example, verbatim: "generateSeries
    // (2, 11, 2)->asStaticArray // => staticarray(2, 4, 6, 8, 10)". This
    // codebase has no distinct StaticArray type (an already-tracked,
    // pre-existing gap — see `NativeTypes.makeGenerateSeriesType`'s own
    // doc comment), so the elements themselves are checked via ->join
    // rather than a literal "staticarray(...)" string match.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        "[generateSeries(2, 11, 2)->asStaticArray->join(',')]",
        context: &context
    )
    #expect(output == "2,4,6,8,10")
}

@Test func aBareStringIsStillNotDirectlyQueriableOnlyEachCharacterIs() async throws {
    // Ch. "Query Expressions", "Making an Object Queriable": "while a
    // string CANNOT be iterated upon directly, it has an iterator
    // string->forEachCharacter, which is implemented as an `eacher`."
    // Confirms this codebase respects that exact distinction — a bare
    // string source still throws (unchanged from every prior stage),
    // while `->eachCharacter` (added this stage) works.
    var context = LassoContext()
    await #expect(throws: (any Error).self) {
        _ = try await LassoRenderer().render(
            "[(with i in 'abc' select #i)->join(',')]",
            context: &context
        )
    }
}

@Test func eachCharacterMatchesTheDocsOwnWorkedExampleVerbatim() async throws {
    // Ch. "Query Expressions" worked example, verbatim: `with i in
    // 'Hammershaimb'->eachCharacter select #i // => H, a, m, m, e, r, s,
    // h, a, i, m, b`.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        "[(with i in 'Hammershaimb'->eachCharacter select #i)->join(',')]",
        context: &context
    )
    #expect(output == "H,a,m,m,e,r,s,h,a,i,m,b")
}

@Test func aCustomTypesOwnForEachMemberMakesItAValidWithSourceMatchingTheDocsOwnUserListExample() async throws {
    // Ch. "Query Expressions", "Making an Object Queriable" worked
    // example, verbatim: a `user_list` type importing `trait_queriable`
    // and implementing `forEach()` by reading the ordinary `givenBlock`
    // keyword and invoking it once per element — then used directly as
    // a with-source: `with user in #ul select #user->first // => Krinn,
    // Ármarinn, Kjarni, Halbjörg, Björg, Hjörtur`. Confirms the Stage
    // 8.5 `query_collector` given-block bridge (`Evaluator
    // .materializeCustomQueriableElements`) correctly reconstructs each
    // labeled `#gb->invoke('Krinn'='Jones')` call into a real Pair
    // (mirroring `register("array")`'s own established label-to-Pair
    // convention), not just the bare value half.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        """
        <?lassoscript
        define user_list => type {
            trait { import trait_queriable }
            public forEach() => {
                local(gb) = givenBlock
                #gb->invoke('Krinn'='Jones')
                #gb->invoke('Ármarinn'='Hammershaimb')
                #gb->invoke('Kjarni'='Jones')
                #gb->invoke('Halbjörg'='Skywalker')
                #gb->invoke('Björg'='Riley')
                #gb->invoke('Hjörtur'='Hammershaimb')
            }
        }
        local(ul) = user_list()
        ?>
        [(with user in #ul select #user->first)->join(',')]
        """,
        context: &context
    ).trimmingCharacters(in: .whitespacesAndNewlines)
    #expect(output == "Krinn,Ármarinn,Kjarni,Halbjörg,Björg,Hjörtur")
}

// MARK: - `@` variable-reference/aliasing operator (Lasso 8.5 Language Guide Ch. 15) -- deliberately unsupported, throws a clear catchable error rather than crashing

@Test func atPrefixOperatorThrowsADedicatedDiagnosticErrorRatherThanTheGenericOneCharacterMessage() async throws {
    // Real Lasso's `@`/[Reference] variable-aliasing system has zero real
    // corpus evidence for its FULL feature (two variable names sharing one
    // mutable storage cell) -- deliberately not built. But bare `@#var`-
    // style usage ("hand back the actual value, not a copy") appears in 6
    // real production files. Rather than the generic, cryptic
    // `unsupportedExpression("@")`, this now throws a dedicated, readable
    // message -- still an ordinary Swift `throws`, never a process crash.
    var context = LassoContext()
    await #expect(throws: LassoRuntimeError.unsupportedExpression(
        "@ (variable-reference/aliasing operator) is not supported"
    )) {
        _ = try await LassoRenderer().render("[local(x)=5][@#x]", context: &context)
    }
}

@Test func atPrefixOperatorThrowsCleanlyAcrossEveryRealCorpusUsageShape() async throws {
    // Every one of these mirrors an actual line from real production
    // corpus files (components/inSite/urlencode.inc, urldecode.inc,
    // tables.inc, results_navigation.inc, components/autoctype.inc,
    // components/inSite/lp_inline_dataset.inc) that uses bare `@` this
    // way. Confirms each shape -- a bare local, a `self->member` chain, a
    // colon-call argument, and a nested nested nested chain -- throws a
    // normal, catchable error (never traps/crashes the process) so a real
    // page hitting any of these fails as an ordinary HTTP error, not a
    // server outage.
    let shapes = [
        "return: @#url_string",
        "return(@#myFeedback)",
    ]
    for shape in shapes {
        var context = LassoContext()
        await #expect(throws: (any Error).self) {
            _ = try await LassoRenderer().render(
                """
                <?lassoscript
                define foo() => {
                    local(url_string, myFeedback) = 'x', 'y'
                    \(shape)
                }
                ?>
                [foo]
                """,
                context: &context
            )
        }
    }

    var selfContext = LassoContext()
    await #expect(throws: (any Error).self) {
        _ = try await LassoRenderer().render(
            """
            <?lassoscript
            define foo => type {
                data public records_array
                public onCreate() => { self->records_array = array(1, 2, 3) }
                public bar() => { return: @self->'records_array'->first }
            }
            local(f) = foo()
            ?>
            [#f->bar]
            """,
            context: &selfContext
        )
    }

    var nestedContext = LassoContext()
    await #expect(throws: (any Error).self) {
        _ = try await LassoRenderer().render(
            """
            <?lassoscript
            define helper(a, b) => { return: #a->asString + ',' + #b->asString }
            define foo => type {
                data public records_array, public field_names
                public onCreate() => { self->records_array = 'RA'; self->field_names = 'FN' }
                public bar() => { return: @(helper: @self->'records_array', @self->'field_names') }
            }
            local(f) = foo()
            ?>
            [#f->bar]
            """,
            context: &nestedContext
        )
    }
}

@Test func atPrefixOperatorErrorIsCaughtByTheServersOwnSiteRenderErrorWrapperNotLeftUncaught() async throws {
    // Confirms the failure mode a real site sees end-to-end: a thrown
    // LassoRuntimeError from `@` propagates as an ordinary Swift error out
    // of `LassoRenderer().render(...)` -- the exact call
    // `LassoPerfectServer`'s own request handler already wraps in a
    // do/catch and re-throws as `LassoSiteRenderError` (turned into a
    // normal HTTP error response for that one request, not a process
    // crash). This test pins that the error surfaces as a plain,
    // catchable `Error` at the render boundary -- the same boundary that
    // server-side wrapping sits on.
    var context = LassoContext()
    var caught: (any Error)?
    do {
        _ = try await LassoRenderer().render("[@#missing]", context: &context)
    } catch {
        caught = error
    }
    #expect(caught != nil)
    #expect(caught is LassoRuntimeError)
}
