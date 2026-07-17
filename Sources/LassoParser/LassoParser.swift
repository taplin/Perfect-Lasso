import Foundation

public struct LassoParser: Sendable {
    public init() {}

    public func parse(_ source: String) -> LassoDocument {
        var scanner = TemplateScanner(source)
        let scanned = scanner.scan()
        var builder = BlockBuilder(nodes: scanned.nodes, diagnostics: scanned.diagnostics, openFormFires: scanned.openFormFires)
        return builder.build()
    }
}

private struct TemplateScanner {
    let characters: [Character]
    var index = 0
    var textStart = 0
    var squareBracketsEnabled = true
    var nodes: [LassoNode] = []
    var diagnostics: [Diagnostic] = []
    /// Tag-open-form recognition counts folded up from every nested
    /// `ScriptBodyParser` this scanner constructs (Phase 3). Plain,
    /// unsynchronized accumulation — this scanner is a value type scoped to
    /// one parse call, never shared across requests.
    var openFormFires: [TagOpenFormFire: Int] = [:]

    private mutating func mergeFires(from other: [TagOpenFormFire: Int]) {
        for (fire, count) in other {
            openFormFires[fire, default: 0] += count
        }
    }

    init(_ source: String) {
        // Swift's `Character` is an extended grapheme cluster, and "\r\n"
        // is exactly one grapheme cluster — a single array element that
        // equals neither the standalone "\r" nor "\n" Character used
        // throughout this file's and ScriptBodyParser's newline checks
        // (readStatement's statement-boundary test, skipLineRemainder's
        // "read until newline", etc.). Real corpus files are commonly
        // CRLF-terminated (Windows-authored Lasso code); left unnormalized,
        // every one of those checks silently fails to recognize a CRLF as
        // a line ending, which let skipLineRemainder swallow everything up
        // to the next *lone* "\n" it could find — in practice, often the
        // rest of a multi-line block body. Normalizing once here, before
        // any downstream parser ever sees a raw Character, fixes every
        // consumer at once (all of ScriptBodyParser/TypeBodyParser operate
        // on substrings sliced from this already-normalized array).
        let normalized = source
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        characters = Array(normalized)
    }

    mutating func scan() -> LassoDocument {
        while index < characters.count {
            if matches("<?lassoscript") {
                emitText(through: index)
                scanDelimited(openLength: 13, close: "?>", delimiter: .lassoscript)
            } else if matches("<?lasso") {
                emitText(through: index)
                scanDelimited(openLength: 7, close: "?>", delimiter: .lasso)
            } else if matches("<?=") {
                emitText(through: index)
                scanDelimited(openLength: 3, close: "?>", delimiter: .echo)
            } else if matches("<!--") {
                emitText(through: index)
                scanHTMLComment()
            } else if squareBracketsEnabled, characters[index] == "[", startsBracketComment(at: index) {
                emitText(through: index)
                scanBracketComment()
            } else if squareBracketsEnabled, characters[index] == "[", startsNoProcess(at: index) != nil {
                emitText(through: index)
                scanNoProcess()
            } else if squareBracketsEnabled, characters[index] == "[" {
                emitText(through: index)
                scanSquare()
            } else {
                index += 1
            }
        }
        emitText(through: characters.count)
        return LassoDocument(nodes: nodes, diagnostics: diagnostics, openFormFires: openFormFires)
    }

    /// Detects the classic `[/* ... */]` idiom, which real Lasso treats as a
    /// code comment that swallows everything (including nested `[ ]` tags and
    /// raw template text) up to the next literal `*/`, not as bracket-tag
    /// content to be parsed as an expression.
    private func startsBracketComment(at position: Int) -> Bool {
        var cursor = position + 1
        while cursor < characters.count, characters[cursor] == " " || characters[cursor] == "\t" {
            cursor += 1
        }
        return cursor + 1 < characters.count && characters[cursor] == "/" && characters[cursor + 1] == "*"
    }

    mutating private func scanBracketComment() {
        let start = index
        index += 1
        while index < characters.count, characters[index] == " " || characters[index] == "\t" {
            index += 1
        }
        index += 2
        while index < characters.count, !matches("*/") { index += 1 }
        guard index < characters.count else {
            diagnostics.append(Diagnostic(message: "Unterminated block comment", range: range(start, index)))
            textStart = index
            return
        }
        index += 2
        while index < characters.count, characters[index] == " " || characters[index] == "\t" {
            index += 1
        }
        if index < characters.count, characters[index] == "]" {
            index += 1
        } else {
            diagnostics.append(Diagnostic(message: "Unterminated square delimiter for block comment", range: range(start, index)))
        }
        textStart = index
    }

    /// Real Lasso's *other* documented raw-content escape hatch, distinct
    /// from `[noprocess]`: Lasso 8.5 Language Guide Chapter 4 ("Escaping
    /// Lasso Code") lists plain HTML comments (`<!-- ... -->`) as an
    /// equally valid way to keep square brackets from being interpreted,
    /// "particularly useful for JavaScript code blocks" — its own worked
    /// example is exactly `<script>` `<!-- array[1] = array[2]; // -->`
    /// `</script>`. Chapter 22 repeats the same guidance verbatim ("client-
    /// side JavaScript... should either be included in [NoProcess]...
    /// [/NoProcess] tags or HTML comment tags <!-- … --> which ensure that
    /// no Lasso code within is processed"). Real corpus evidence: 11
    /// `templates/*/master.template.lasso` files all use exactly this
    /// pattern for a Bootstrap-style modal-init snippet
    /// (`$.HSCore.components.HSModalWindow.init('[data-modal-target]');`)
    /// — `[data-modal-target]` was being scanned as a real Lasso bracket
    /// tag (`unsupportedExpression("-modal")`) despite already being
    /// wrapped exactly the documented way; this interpreter simply never
    /// implemented the HTML-comment half of the documented escape
    /// mechanism, only the `[noprocess]` half.
    ///
    /// Unlike `[noprocess]`, the delimiters here are real HTML syntax a
    /// browser must actually see to treat the span as a comment — so
    /// (unlike `scanNoProcess`, which strips its `[noprocess]`/
    /// `[/noprocess]` markers) the entire `<!--...-->` span, delimiters
    /// included, is emitted verbatim as one `.text(...)` node.
    mutating private func scanHTMLComment() {
        let start = index
        index += 4 // "<!--"
        while index < characters.count, !matches("-->") { index += 1 }
        if index < characters.count {
            index += 3 // "-->"
        } else {
            diagnostics.append(Diagnostic(message: "Unterminated HTML comment", range: range(start, index)))
        }
        nodes.append(.text(String(characters[start..<index]), range(start, index)))
        textStart = index
    }

    /// `[noprocess]`/`[no_process]` (real Lasso's raw-content escape hatch —
    /// used throughout the real corpus to embed non-Lasso content, most
    /// often JavaScript, that would otherwise collide with `[ ]` bracket-tag
    /// scanning) with nothing but optional whitespace between the name and
    /// the closing `]`. Returns the matched span's total length (through
    /// the opening `]`) or `nil` if this isn't actually a noprocess opener.
    private func startsNoProcess(at position: Int) -> Int? {
        var cursor = position + 1
        let name = readIdentifierLookahead(from: &cursor)
        guard name.lowercased() == "noprocess" || name.lowercased() == "no_process" else { return nil }
        while cursor < characters.count, characters[cursor] == " " || characters[cursor] == "\t" {
            cursor += 1
        }
        guard cursor < characters.count, characters[cursor] == "]" else { return nil }
        return cursor + 1 - position
    }

    private func readIdentifierLookahead(from cursor: inout Int) -> String {
        let start = cursor
        while cursor < characters.count,
              characters[cursor].isLetter || characters[cursor].isNumber || characters[cursor] == "_" {
            cursor += 1
        }
        return String(characters[start..<cursor])
    }

    /// Everything between the opening `[noprocess]`/`[no_process]` and its
    /// matching literal closing tag is real Lasso's documented raw-content
    /// escape: emitted verbatim as plain text, never scanned for nested
    /// `<?lasso ?>`/`[ ]` constructs at all — unlike every other block tag
    /// in this scanner, which stays inside the normal recursive scan.
    /// Accepts either spelling on the close regardless of which spelling
    /// opened it (real corpus content is inconsistent about which one it
    /// uses, though `noprocess` is by far the dominant spelling).
    mutating private func scanNoProcess() {
        let start = index
        guard let openLength = startsNoProcess(at: index) else { return }
        index += openLength
        let bodyStart = index

        while index < characters.count {
            if characters[index] == "[", let closeLength = matchesNoProcessClose(at: index) {
                let body = String(characters[bodyStart..<index])
                nodes.append(.text(body, range(bodyStart, index)))
                index += closeLength
                textStart = index
                return
            }
            index += 1
        }

        diagnostics.append(Diagnostic(message: "Unterminated [noprocess] block", range: range(start, index)))
        nodes.append(.text(String(characters[bodyStart..<index]), range(bodyStart, index)))
        textStart = index
    }

    private func matchesNoProcessClose(at position: Int) -> Int? {
        var cursor = position + 1
        guard cursor < characters.count, characters[cursor] == "/" else { return nil }
        cursor += 1
        let name = readIdentifierLookahead(from: &cursor)
        guard name.lowercased() == "noprocess" || name.lowercased() == "no_process" else { return nil }
        while cursor < characters.count, characters[cursor] == " " || characters[cursor] == "\t" {
            cursor += 1
        }
        guard cursor < characters.count, characters[cursor] == "]" else { return nil }
        return cursor + 1 - position
    }

    mutating private func scanDelimited(openLength: Int, close: String, delimiter: LassoDelimiter) {
        let start = index
        index += openLength
        let bodyStart = index
        while index < characters.count, !matches(close) { index += 1 }
        let body = String(characters[bodyStart..<index])
        if index == characters.count {
            diagnostics.append(Diagnostic(
                message: "Unterminated \(delimiter.rawValue) delimiter",
                range: range(start, index)
            ))
        } else {
            index += close.count
        }
        emitCode(body, dialect: .lasso9, delimiter: delimiter, range: range(start, index))
        textStart = index
    }

    mutating private func scanSquare() {
        let start = index
        index += 1
        let bodyStart = index
        var quote: Character?
        while index < characters.count {
            let character = characters[index]
            if let activeQuote = quote {
                // A backslash-escaped quote (`'it\'s'`) must not be
                // mistaken for the string's real closing quote — found
                // testing `[Encode_SQL: 'it\'s']`, where this scanner
                // (unlike `ExpressionParser.readString`, which already
                // handles this correctly) ended the string one character
                // early, then misread the real closing quote as opening a
                // new one, losing track of the bracket's true `]`.
                if character == "\\", index + 1 < characters.count {
                    index += 2
                    continue
                }
                if character == activeQuote { quote = nil }
                index += 1
                continue
            }
            // A real bracket span can hold a `//` or `/* ... */` comment
            // (e.g. the `[//lasso` file-header idiom borrowed from
            // lassosoft.com/tagswap) whose content is not itself Lasso
            // code — quotes and `]` characters inside it (an apostrophe in
            // a name, a `[tag(...)]` example in prose) must not be
            // mistaken for a real string delimiter or the bracket's own
            // closing `]`. Skipped here purely to find the true close;
            // the comment text itself still reaches `emitCode`'s body,
            // same as it always has.
            if matches("//") {
                while index < characters.count, characters[index] != "\n" {
                    index += 1
                }
                continue
            }
            if matches("/*") {
                index += 2
                while index < characters.count, !matches("*/") {
                    index += 1
                }
                index = min(index + 2, characters.count)
                continue
            }
            if character == "'" || character == "\"" {
                quote = character
            } else if character == "]" {
                break
            }
            index += 1
        }
        guard index < characters.count else {
            diagnostics.append(Diagnostic(message: "Unterminated square delimiter", range: range(start, index)))
            textStart = start
            return
        }
        let body = String(characters[bodyStart..<index]).trimmingCharacters(in: .whitespacesAndNewlines)
        index += 1
        emitCode(body, dialect: inferDialect(body), delimiter: .square, range: range(start, index))
        if body.lowercased() == "no_square_brackets" { squareBracketsEnabled = false }
        textStart = index
    }

    mutating private func emitCode(
        _ body: String,
        dialect: LassoDialect,
        delimiter: LassoDelimiter,
        range: SourceRange
    ) {
        // A legacy closing tag is a single '/' immediately followed by a
        // tag name (`[/if]`, `[/lp_client_browser]`) — never '//' or '/*'.
        // Excluding those keeps a bracket body that opens with a comment
        // (the `[//lasso ... ]` file-header idiom found in real startup
        // libraries) from being misread as a bogus closing tag whose
        // "name" swallows the entire rest of the body, silently discarding
        // all the real code that follows.
        if body.hasPrefix("/"), !body.hasPrefix("//"), !body.hasPrefix("/*") {
            let name = body.dropFirst().trimmingCharacters(in: .whitespacesAndNewlines)
            nodes.append(.tag(name: name, arguments: [], closing: true, dialect: .lasso8, range: range))
            return
        }

        if delimiter == .square, let defineTag = Self.parseDefineTag(body: body, dialect: dialect, range: range) {
            nodes.append(defineTag)
            return
        }

        // A whole `define name(...) => { ... }` custom tag can be wrapped
        // in a single `[ ... ]` span rather than the `[define ...] ...
        // [/define]` paired style `parseDefineTag` above handles — a real
        // idiom (`[//lasso ... define ... => { ... } ]`) found in startup
        // libraries downloaded from lassosoft.com/tagswap, where `//lasso`
        // is just an ordinary leading comment, not a directive. This needs
        // the same statement/block-aware parsing `<?lasso ?>` content
        // gets, not the single-expression path below, which would only
        // keep the first (comment-garbled) parsed expression and silently
        // drop the tag's real body entirely.
        if delimiter == .square, Self.bodyOpensWithDefine(body) {
            var parser = ScriptBodyParser(source: body, range: range, delimiter: .square)
            nodes.append(contentsOf: parser.parse())
            diagnostics.append(contentsOf: parser.diagnostics)
            mergeFires(from: parser.openFormFires)
            return
        }

        // Legacy `define_tag`/`define_type` startup libraries commonly wrap
        // their ENTIRE multi-statement, semicolon-separated body (opener,
        // nested local()/define_tag() calls, /define_tag;/-style closers) in
        // one square-bracket span — see Documentation/legacy-define-tag-type-plan.md.
        // The generic path below only keeps the first parsed expression,
        // which would silently drop everything after the opening call
        // (confirmed directly: a real `[Define_Tag(...); ...; /Define_Tag;]`
        // body collapsed to just the opening call before this fix). Needs
        // the same statement/block-aware ScriptBodyParser treatment as
        // modern `define`, not the single-expression fallback.
        if delimiter == .square, Self.bodyOpensWithLegacyDefinition(body) {
            var parser = ScriptBodyParser(source: body, range: range, delimiter: .square)
            let parsed = parser.parse()
            nodes.append(contentsOf: parsed)
            diagnostics.append(contentsOf: parser.diagnostics)
            mergeFires(from: parser.openFormFires)
            return
        }

        // <?lasso ?> and <?= ?> content is one continuous span of code
        // between the delimiters — not template text interspersed with
        // tags, the shape bracket dialect has — so it needs the same
        // statement/block-aware grammar <?lassoscript ?> already has
        // (ScriptBodyParser), not the flat expression list ExpressionParser
        // produces on its own. Real startup libraries commonly hold
        // if/loop control flow inside plain <?lasso ?>, which ExpressionParser
        // has no concept of at all.
        if delimiter == .lassoscript || delimiter == .lasso || delimiter == .echo {
            var parser = ScriptBodyParser(source: body, range: range, delimiter: delimiter)
            nodes.append(contentsOf: parser.parse())
            diagnostics.append(contentsOf: parser.diagnostics)
            mergeFires(from: parser.openFormFires)
            return
        }

        var parser = ExpressionParser(body)
        let expressions = parser.parseList()
        if delimiter == .square, let first = expressions.first {
            if expressions.count > 1,
               case let .call(callee, _) = first,
               case let .identifier(name) = callee,
               TagCatalog.isBlock(name, in: .lassoParser) {
                // A whole block-tag statement — condition, body, `else`,
                // closing `/name` — embedded in ONE square-bracket span,
                // e.g. real corpus's `[if($product_subset == 'all')
                // var(temp_tbl='ca_web') else var(temp_tbl='lc_web') /if]`
                // (pages/subcats.page.lasso). The plain path below only
                // keeps `expressions.first` (the opening call) and
                // silently drops everything after it in this same body —
                // no body, no `else`, no closing tag ever becomes a real
                // node — so `BlockBuilder` pairs this phantom open with
                // whatever `[/if]`/`[else]` happens to appear *later* in
                // the page, silently swallowing real content in between
                // (confirmed live: this exact page's category list and
                // product thumbnails never rendered). `expressions.count
                // > 1` is the signal that more than just the opening call
                // was parsed from this one span — needs the same
                // statement/block-aware `ScriptBodyParser` treatment
                // `bodyOpensWithDefine`/`bodyOpensWithLegacyDefinition`
                // above already get for the same reason.
                var scriptParser = ScriptBodyParser(source: body, range: range, delimiter: .square)
                nodes.append(contentsOf: scriptParser.parse())
                diagnostics.append(contentsOf: scriptParser.diagnostics)
                mergeFires(from: scriptParser.openFormFires)
                return
            }
            if case let .call(callee, arguments) = first,
               case let .identifier(name) = callee,
               TagCatalog.isBlock(name, in: .lassoParser) {
                nodes.append(.tag(name: name, arguments: arguments, closing: false, dialect: dialect, range: range))
            } else if case let .identifier(name) = first,
                      TagCatalog.allowsBareOpen(name, in: .lassoParser) {
                nodes.append(.tag(name: name, arguments: [], closing: false, dialect: dialect, range: range))
            } else if expressions.count > 1 {
                // Multiple ordinary (non-block-tag) statements in one
                // square-bracket span — e.g. real corpus's
                // tims_loader.lasso: `[include('/a.inc')
                // include('/b.inc') include('/c.inc')]`, three
                // sequential calls with no block-tag body/closer among
                // them, so the `expressions.count > 1` branch above
                // (which only fires when `first` is itself a
                // `.lassoParser`-scope block call) never triggers. Falling to
                // `.expression(first, ...)` below kept only the very
                // first call and silently dropped the rest — the second
                // and third `include()` calls (and every `define`
                // inside them) never ran at all.
                nodes.append(.code(expressions, dialect, delimiter, range))
            } else {
                nodes.append(.expression(first, dialect, delimiter, range))
            }
        } else {
            nodes.append(.code(expressions, dialect, delimiter, range))
        }
    }

    /// Handles `[define tagname(params)] ... [/define]`. The generic
    /// call-shape detection above only looks at the first parsed
    /// expression, which for this input is the bare keyword `define` —
    /// `tagname` and its parameter list would otherwise be silently
    /// dropped. Keeps the emitted tag's `name` as the literal `"define"`
    /// keyword (so the existing `[/define]` open/close pairing in
    /// `BlockBuilder` keeps working unchanged) and carries the real tag
    /// name as a synthetic first argument, matching the shape script-mode
    /// `define` produces.
    private static func parseDefineTag(
        body: String,
        dialect: LassoDialect,
        range: SourceRange
    ) -> LassoNode? {
        guard body.lowercased().hasPrefix("define") else { return nil }
        let afterKeyword = body.index(body.startIndex, offsetBy: "define".count)
        guard afterKeyword < body.endIndex, body[afterKeyword].isWhitespace else { return nil }

        let remainder = String(body[afterKeyword...]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !remainder.isEmpty else { return nil }

        var parser = ExpressionParser(remainder)
        let expression = parser.parseExpression()
        let name: String
        let parameters: [LassoArgument]
        switch expression {
        case let .call(callee, arguments):
            guard case let .identifier(calleeName) = callee else { return nil }
            name = calleeName
            parameters = arguments
        case let .identifier(bareName):
            name = bareName
            parameters = []
        default:
            return nil
        }

        let nameArgument = LassoArgument(label: nil, value: .string(name))
        return .tag(
            name: "define",
            arguments: [nameArgument] + parameters,
            closing: false,
            dialect: dialect,
            range: range
        )
    }

    mutating private func emitText(through end: Int) {
        guard end > textStart else { return }
        nodes.append(.text(String(characters[textStart..<end]), range(textStart, end)))
    }

    /// True if `body`, once any leading `//` or `/* ... */` comments and
    /// whitespace are skipped, starts with the `define` keyword as a whole
    /// word. Unlike `parseDefineTag` above, this tolerates leading
    /// comments (needed for the `[//lasso ... define ... ]` idiom) and
    /// doesn't attempt to parse out a name/parameter list itself — the
    /// caller routes a match through `ScriptBodyParser`, which already
    /// knows how to do that correctly for a full `define ... => { ... }`
    /// body, comments and all.
    private static func bodyOpensWithDefine(_ body: String) -> Bool {
        let characters = Array(body)
        var index = 0
        while index < characters.count {
            if characters[index].isWhitespace {
                index += 1
            } else if index + 1 < characters.count, characters[index] == "/", characters[index + 1] == "/" {
                while index < characters.count, characters[index] != "\n" { index += 1 }
            } else if index + 1 < characters.count, characters[index] == "/", characters[index + 1] == "*" {
                index += 2
                while index + 1 < characters.count, !(characters[index] == "*" && characters[index + 1] == "/") {
                    index += 1
                }
                index = min(index + 2, characters.count)
            } else {
                break
            }
        }
        let remainder = String(characters[index...])
        guard remainder.lowercased().hasPrefix("define") else { return false }
        let afterKeyword = remainder.index(remainder.startIndex, offsetBy: "define".count)
        return afterKeyword == remainder.endIndex || remainder[afterKeyword].isWhitespace
    }

    /// Same leading-comment-tolerant scan as `bodyOpensWithDefine`, but for
    /// legacy block keywords (`define_tag`/`define_type`, and the
    /// `output_none`/`html_comment`/`encode_set` container tags — see
    /// Documentation/output-tags-plan.md) instead of modern `define`. Both
    /// the parenthesized-call (`define_tag(...)`) and colon-call
    /// (`define_tag:`) openers need to match — the character immediately
    /// after the keyword is `(`, `:`, whitespace, or end.
    private static func bodyOpensWithLegacyDefinition(_ body: String) -> Bool {
        let characters = Array(body)
        var index = 0
        while index < characters.count {
            if characters[index].isWhitespace {
                index += 1
            } else if index + 1 < characters.count, characters[index] == "/", characters[index + 1] == "/" {
                while index < characters.count, characters[index] != "\n" { index += 1 }
            } else if index + 1 < characters.count, characters[index] == "/", characters[index + 1] == "*" {
                index += 2
                while index + 1 < characters.count, !(characters[index] == "*" && characters[index + 1] == "/") {
                    index += 1
                }
                index = min(index + 2, characters.count)
            } else {
                break
            }
        }
        let remainder = String(characters[index...])
        for keyword in ["define_tag", "define_type", "output_none", "html_comment", "encode_set"] {
            guard remainder.lowercased().hasPrefix(keyword) else { continue }
            let afterKeyword = remainder.index(remainder.startIndex, offsetBy: keyword.count)
            if afterKeyword == remainder.endIndex { return true }
            let next = remainder[afterKeyword]
            // `;` matters for keywords real corpus uses with zero
            // arguments and no colon (`Output_None;` directly, not
            // `Output_None:` or `Output_None (`) — found testing exactly
            // this shape.
            if next.isWhitespace || next == "(" || next == ":" || next == ";" { return true }
        }
        return false
    }

    private func inferDialect(_ body: String) -> LassoDialect {
        if body.hasPrefix("/") || body.contains("$") ||
            body.range(of: #"^[A-Za-z_][A-Za-z0-9_]*\s*:"#,
                       options: .regularExpression) != nil {
            return .lasso8
        }
        return .lasso9
    }

    private func matches(_ text: String) -> Bool {
        let candidate = Array(text.lowercased())
        guard index + candidate.count <= characters.count else { return false }
        return characters[index..<(index + candidate.count)].map { Character($0.lowercased()) } == candidate
    }

    private func range(_ start: Int, _ end: Int) -> SourceRange {
        SourceRange(start: position(start), end: position(end))
    }

    private func position(_ offset: Int) -> SourcePosition {
        var line = 1
        var column = 1
        for character in characters.prefix(offset) {
            if character == "\n" {
                line += 1
                column = 1
            } else {
                column += 1
            }
        }
        return SourcePosition(offset: offset, line: line, column: column)
    }

}
