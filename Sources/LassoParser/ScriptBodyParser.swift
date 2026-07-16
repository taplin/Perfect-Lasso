import Foundation

struct ScriptBodyParser {
    private let characters: [Character]
    private let range: SourceRange
    private let delimiter: LassoDelimiter
    private var index = 0
    private var nodes: [LassoNode] = []
    private(set) var diagnostics: [Diagnostic] = []
    /// Names of block keywords currently open via an arrow-brace body
    /// (`if(...) => { ... }`), so a later bare `}` — which by itself
    /// carries no name — knows which block it's closing. Slash-closed
    /// blocks (`if(...) ... /if`) never touch this; they're matched by
    /// `parseClosingTag` directly.
    private var openBraceBlockStack: [String] = []

    init(source: String, range: SourceRange, delimiter: LassoDelimiter = .lassoscript) {
        characters = Array(source)
        self.range = range
        self.delimiter = delimiter
    }

    mutating func parse() -> [LassoNode] {
        while index < characters.count {
            skipTrivia()
            guard index < characters.count else { break }

            if parseClosingTag() { continue }
            if parseElseTag() { continue }
            if parseCaseTag() { continue }
            if parseDefineOpening() { continue }
            if parseWithOpening() { continue }
            if parseBlockOpening() { continue }
            if parseIgnoredBrace() { continue }

            let statementStart = index
            let statement = readStatement()
            emitStatement(statement, start: statementStart, end: index)
        }
        for openName in openBraceBlockStack.reversed() {
            diagnostics.append(Diagnostic(message: "Unclosed \(openName) block", range: range))
        }
        openBraceBlockStack.removeAll()
        return nodes
    }

    private mutating func parseClosingTag() -> Bool {
        guard characters[index] == "/" else { return false }
        let start = index
        index += 1
        let name = readIdentifier()
        guard !name.isEmpty else {
            index = start
            return false
        }
        skipLineRemainder()
        nodes.append(.tag(name: name, arguments: [], closing: true, dialect: .lasso9, range: range))
        return true
    }

    private mutating func parseElseTag() -> Bool {
        let start = index
        guard readKeyword("else") else { return false }
        skipHorizontalWhitespace()

        var arguments: [LassoArgument] = []
        if index < characters.count, characters[index] == "(" {
            let body = readBalanced(open: "(", close: ")")
            arguments = parseCallArguments(name: "else", body: body)
        }
        // If this branch itself opens with an arrow-brace body, no push is
        // needed here: the preceding if's own closing brace deliberately
        // left its "if" entry on the stack instead of popping it (see
        // parseIgnoredBrace) precisely so this branch's closing brace is
        // what finally pops it — matching how a trailing `/if` already
        // closes both branches of a slash-style `if(...) ... else ...
        // /if` today with a single closing signal.
        _ = consumeArrowBlockStartIfPresent()
        skipLineRemainder()
        if characters.indices.contains(start) {
            nodes.append(.tag(name: "else", arguments: arguments, closing: false, dialect: .lasso9, range: range))
        }
        return true
    }

    /// Handles `Case(value);`/bare `Case;` inside a free-tag
    /// `Select(...); ... /Select;` block — a flat branch separator, not a
    /// paired block, exactly like `else` above. Real corpus's only
    /// free-tag example (`includes/Calculate_Day.include.lasso`) always
    /// parenthesizes its value (`Case(1);` ... `Case(7);`); the bare form
    /// (Lasso 8.5's documented default-case marker) is supported here too
    /// since it costs nothing extra and matches the bracket-tag dialect's
    /// `[Case]` default form exactly. An out-of-context `case` (no
    /// enclosing `Select`) is left for `BlockBuilder` to silently ignore
    /// as an ordinary flat tag — matching real Select/Case's own zero
    /// evidence of malformed usage.
    private mutating func parseCaseTag() -> Bool {
        let start = index
        guard readKeyword("case") else { return false }
        skipHorizontalWhitespace()

        var arguments: [LassoArgument] = []
        if index < characters.count, characters[index] == "(" {
            let body = readBalanced(open: "(", close: ")")
            arguments = parseCallArguments(name: "case", body: body)
        }
        skipLineRemainder()
        if characters.indices.contains(start) {
            nodes.append(.tag(name: "case", arguments: arguments, closing: false, dialect: .lasso9, range: range))
        }
        return true
    }

    private mutating func parseBlockOpening() -> Bool {
        let start = index
        let name = readIdentifier()
        guard !name.isEmpty else { return false }
        let normalized = name.lowercased()
        guard let entry = TagCatalog.entry(normalized), entry.blockScopes.contains(.scriptBody) else {
            index = start
            return false
        }

        // "if" is the only scriptBody block with a real `.bareCondition`
        // form (see TagOpenForm's doc) — route it through the exhaustive
        // classifier/switch in parseIfOpening. Every other block name
        // keeps using the shared cascade below, untouched: this fork
        // exists specifically so that restructuring can't accidentally
        // change behavior for tags it was never meant to touch (tag-form
        // consolidation Commit B — see TagCatalog.swift).
        if entry.openForms.contains(.bareCondition) {
            return parseIfOpening(name: name, statementStart: start)
        }

        skipHorizontalWhitespace()
        // Lasso 8's colon-call convention (`if:(condition);` ... `/if;`)
        // is just as valid an opener as the parenthesized-call style
        // (`if(condition)`) — found live-verifying a real corpus page,
        // where `if:(...)` fell through to being parsed as an ordinary
        // colon-call expression statement (`if` treated as a bare
        // function name), throwing unknownFunction("if") at evaluation
        // time instead of ever reaching real if/else control flow.
        if index < characters.count, characters[index] == ":" {
            index += 1
            skipHorizontalWhitespace()
        }
        guard index < characters.count, characters[index] == "(" else {
            index = start
            return false
        }

        let body = readBalanced(open: "(", close: ")")
        let arguments = parseCallArguments(name: name, body: body)
        if consumeArrowBlockStartIfPresent() {
            openBraceBlockStack.append(name)
        }
        skipLineRemainder()
        nodes.append(.tag(name: name, arguments: arguments, closing: false, dialect: .lasso9, range: range))
        return true
    }

    /// The result of actually inspecting the character stream for "if"'s
    /// three surface forms — as opposed to a `TagOpenForm` value assigned
    /// from a compile-time literal, this is a genuinely *computed*
    /// classification, so the `switch` in `parseIfOpening` that dispatches
    /// on it is load-bearing: a new case added here that dispatch doesn't
    /// handle is a real compile error over real logic, not a tautology.
    /// (An earlier version of this code assigned `let form: TagOpenForm =
    /// .bareCondition` one line above its own `switch form`, which type-
    /// checks as "exhaustive" but is a switch over a constant — it can't
    /// catch anything a future form would break. Fixed after review.)
    private enum IfOpenClassification {
        case parenOrColonCall(TagOpenForm)
        /// The bare-condition form fully validated (non-empty condition,
        /// real arrow-brace-or-bare-brace body start already consumed) —
        /// carries the trimmed condition text, since re-deriving it would
        /// mean re-scanning already-consumed input.
        case bareCondition(String)
    }

    /// Classifies which of "if"'s three forms is present at the current
    /// position, in the same priority order the shared cascade in
    /// `parseBlockOpening` uses for every other block name (an optional
    /// colon-prefix consumed first, then a paren-check, then the
    /// bare-condition fallback). Returns `nil` — with `index` rewound to
    /// wherever it started this call — if none match; every match leaves
    /// `index` positioned exactly where the pre-consolidation cascade did.
    private mutating func classifyIfOpen(colonConsumed: Bool) -> IfOpenClassification? {
        if index < characters.count, characters[index] == "(" {
            return .parenOrColonCall(colonConsumed ? .colonCall : .parenCall)
        }

        // Real Lasso 9 also allows `if` with a bare, paren-less condition
        // immediately followed by a brace body (`if #request == '' { ... }
        // else { ... }`) — distinct from both `if(cond) ... /if` and
        // `if(cond) => { ... }`. Found live: components/site_setup_tags.inc's
        // excludeBots(), called unconditionally on every page via
        // _begin.lasso -> library().
        let bareConditionStart = index
        if let condition = readBareConditionBeforeBraceBody() {
            let trimmedCondition = condition.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedCondition.isEmpty, consumeArrowBlockStartIfPresent() {
                return .bareCondition(trimmedCondition)
            }
            index = bareConditionStart
        }

        return nil
    }

    private mutating func parseIfOpening(name: String, statementStart: Int) -> Bool {
        skipHorizontalWhitespace()
        let colonConsumed = index < characters.count && characters[index] == ":"
        if colonConsumed {
            index += 1
            skipHorizontalWhitespace()
        }

        guard let classification = classifyIfOpen(colonConsumed: colonConsumed) else {
            index = statementStart
            return false
        }

        switch classification {
        case let .parenOrColonCall(form):
            switch form {
            case .parenCall, .colonCall:
                break
            case .bareCondition, .bareIdentifier:
                preconditionFailure("classifyIfOpen's .parenOrColonCall case only ever carries .parenCall/.colonCall")
            }
            let body = readBalanced(open: "(", close: ")")
            let arguments = parseCallArguments(name: name, body: body)
            if consumeArrowBlockStartIfPresent() {
                openBraceBlockStack.append(name)
            }
            skipLineRemainder()
            nodes.append(.tag(name: name, arguments: arguments, closing: false, dialect: .lasso9, range: range))
            return true
        case let .bareCondition(trimmedCondition):
            openBraceBlockStack.append(name)
            var conditionParser = ExpressionParser(trimmedCondition)
            let conditionExpression = conditionParser.parseExpression()
            skipLineRemainder()
            nodes.append(.tag(
                name: name,
                arguments: [LassoArgument(label: nil, value: conditionExpression)],
                closing: false,
                dialect: .lasso9,
                range: range
            ))
            return true
        }
    }

    /// Handles `define name(params) => { body }`, compiling a reusable
    /// custom tag directly (bypassing the flat open/close-tag pairing the
    /// rest of this parser uses, since the whole nested body is already in
    /// hand once the balanced `{ }` is extracted). `define Foo => type {
    /// ... }` object/type definitions are parsed into a first-pass runtime
    /// type definition and registered when rendered.
    private mutating func parseDefineOpening() -> Bool {
        let start = index
        guard readKeyword("define") else { return false }
        skipHorizontalWhitespace()

        let name = readIdentifier()
        guard !name.isEmpty else {
            diagnostics.append(Diagnostic(message: "Malformed 'define': expected a tag name", range: range))
            index = start
            return false
        }
        skipHorizontalWhitespace()

        var parameters: [LassoArgument] = []
        if index < characters.count, characters[index] == "(" {
            let body = readBalanced(open: "(", close: ")")
            parameters = parseCallArguments(name: name, body: body)
            skipHorizontalWhitespace()
        }

        if matches("::") {
            index += 2
            _ = readIdentifier()
            skipHorizontalWhitespace()
        }

        guard matches("=>") else {
            diagnostics.append(Diagnostic(message: "Malformed 'define \(name)': expected '=>'", range: range))
            index = start
            return false
        }
        index += 2
        // The body's opening brace commonly sits on its own line after
        // `=>` in real code (`define name(...) =>\n{`), not just on the
        // same line. Full trivia skipping (whitespace and comments, not
        // just same-line spaces) here is what makes that layout parse.
        skipTrivia()

        if readKeyword("type") {
            skipTrivia()
            guard index < characters.count, characters[index] == "{" else {
                diagnostics.append(Diagnostic(message: "Malformed 'define \(name) => type': expected '{'", range: range))
                return true
            }
            let bodySource = readBalanced(open: "{", close: "}")
            skipLineRemainder()
            var typeParser = TypeBodyParser(source: bodySource, typeName: name, range: range)
            let definition = typeParser.parse()
            diagnostics.append(contentsOf: typeParser.diagnostics)
            nodes.append(.typeDefinition(definition, .lasso9, range))
            return true
        }

        guard index < characters.count, characters[index] == "{" else {
            // No brace body at all — a constant-style define
            // (`define name => <expr>`), real in startup libraries for
            // string/array/map literals. readStatement() already tracks
            // paren depth and quotes, so a multi-line array(...)/map(...)
            // body reads as one statement rather than stopping at each
            // internal newline. Mirrors TypeBodyParser.parseExpressionMethodBody,
            // which solves the identical problem for type methods.
            let expressionSource = readStatement()
            let trimmedExpression = expressionSource.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedExpression.isEmpty else {
                diagnostics.append(Diagnostic(message: "Malformed 'define \(name) => ': expected an expression or '{'", range: range))
                index = start
                return false
            }
            var expressionParser = ExpressionParser("return(\(trimmedExpression))")
            let nameArgument = LassoArgument(label: nil, value: .string(name))
            nodes.append(.block(
                name: "define",
                arguments: [nameArgument] + parameters,
                body: [.code(expressionParser.parseList(), .lasso9, .lassoscript, range)],
                alternate: nil,
                dialect: .lasso9,
                range: range
            ))
            return true
        }
        let bodySource = readBalanced(open: "{", close: "}")
        skipLineRemainder()

        var nestedParser = ScriptBodyParser(source: bodySource, range: range)
        let flatNestedBody = nestedParser.parse()
        diagnostics.append(contentsOf: nestedParser.diagnostics)
        // parse() returns a flat open/close-tag stream — pairing it into
        // nested .block structures (if/loop/inline/etc.) is normally a
        // separate BlockBuilder pass that only runs at the top-level
        // LassoParser.parse() entry. Run it here too, since this body is
        // parsed independently of that entry point.
        var nestedBuilder = BlockBuilder(nodes: flatNestedBody, diagnostics: [])
        let nestedResult = nestedBuilder.build()
        diagnostics.append(contentsOf: nestedResult.diagnostics)

        let nameArgument = LassoArgument(label: nil, value: .string(name))
        nodes.append(.block(
            name: "define",
            arguments: [nameArgument] + parameters,
            body: nestedResult.nodes,
            alternate: nil,
            dialect: .lasso9,
            range: range
        ))
        return true
    }

    /// Handles `with name in expression do { body }` iteration — a real
    /// startup-library construct with no slash-closed form in evidence,
    /// only the brace-bodied shape. Unlike `iterate` (fixed `loop_value`
    /// local), the per-iteration binding name is whatever the source wrote
    /// (`with bot in botMap do { ... #bot ... }`), so the name travels as a
    /// synthetic first argument, matching the `define`/`[define ...]`
    /// pattern of carrying a real identifier as a `.string` argument.
    private mutating func parseWithOpening() -> Bool {
        let start = index
        guard readKeyword("with") else { return false }
        skipHorizontalWhitespace()

        let variableName = readIdentifier()
        guard !variableName.isEmpty else {
            diagnostics.append(Diagnostic(message: "Malformed 'with': expected a variable name", range: range))
            index = start
            return false
        }
        skipHorizontalWhitespace()

        guard readKeyword("in") else {
            diagnostics.append(Diagnostic(message: "Malformed 'with \(variableName)': expected 'in'", range: range))
            index = start
            return false
        }
        skipHorizontalWhitespace()

        let sourceText = readUntilKeyword("do")
        let trimmedSource = sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSource.isEmpty else {
            diagnostics.append(Diagnostic(message: "Malformed 'with \(variableName) in': expected an expression before 'do'", range: range))
            index = start
            return false
        }
        skipHorizontalWhitespace()

        guard readKeyword("do") else {
            diagnostics.append(Diagnostic(message: "Malformed 'with \(variableName) in ...': expected 'do'", range: range))
            index = start
            return false
        }
        skipTrivia()

        guard index < characters.count, characters[index] == "{" else {
            diagnostics.append(Diagnostic(message: "Malformed 'with \(variableName) in ... do': expected '{'", range: range))
            index = start
            return false
        }
        index += 1
        openBraceBlockStack.append("with")

        var sourceParser = ExpressionParser(trimmedSource)
        let sourceExpression = sourceParser.parseExpression()
        let nameArgument = LassoArgument(label: nil, value: .string(variableName))
        let sourceArgument = LassoArgument(label: nil, value: sourceExpression)
        nodes.append(.tag(name: "with", arguments: [nameArgument, sourceArgument], closing: false, dialect: .lasso9, range: range))
        return true
    }

    private mutating func parseIgnoredBrace() -> Bool {
        guard characters[index] == "}" else { return false }
        index += 1
        // A brace-style if's own closing brace, when immediately followed
        // by `else`, does not close the if/else construct yet — only "if"
        // can have a following else in this language, so this check is
        // scoped to that case. Leaving the "if" entry on the stack here is
        // what lets the else branch's own closing brace (below) be the one
        // that finally pops it, matching how a trailing `/if` already
        // closes both branches of a slash-style if/else with one signal.
        if openBraceBlockStack.last?.caseInsensitiveCompare("if") == .orderedSame, peekIsElseKeyword() {
            return true
        }
        if let closedName = openBraceBlockStack.popLast() {
            nodes.append(.tag(name: closedName, arguments: [], closing: true, dialect: .lasso9, range: range))
        } else {
            diagnostics.append(Diagnostic(message: "Unexpected closing brace", range: range))
        }
        skipLineRemainder()
        return true
    }

    private mutating func emitStatement(_ statement: String, start: Int, end: Int) {
        let trimmed = statement.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // A precise per-statement range (this parser's constant `range`
        // covers the *entire* script-mode span it was constructed with —
        // e.g. a whole `<?lasso ... ?>` block — which made every emitted
        // node report the exact same "line 1, column 1"-ish location
        // regardless of which statement actually failed).
        let statementRange = SourceRange(start: position(start), end: position(end))
        var parser = ExpressionParser(normalizeReturn(trimmed))
        let expressions = parser.parseList()
        guard expressions.count == 1 else {
            if !expressions.isEmpty {
                nodes.append(.code(expressions, .lasso9, delimiter, statementRange))
            }
            return
        }
        // Several block-shaped keywords commonly use Lasso 8's bare
        // colon-call convention with no enclosing parens at all
        // (`Define_Tag: 'name', -Required='x';`, or even zero arguments —
        // `Output_None;` ... `/Output_None;` — appears constantly in real
        // startup/page code with no parens whatsoever), unlike
        // `parseBlockOpening`'s `if:(...)`/`loop:(...)` handling, which
        // still requires parens after the colon. That shape parses fine as
        // an ordinary call/bare-identifier expression here — it just needs
        // to become a `.tag(...)` node (matching `parseBlockOpening`'s
        // output) instead of `.code(...)` so `BlockBuilder` can pair it
        // with its `/name;` closer. See
        // Documentation/legacy-define-tag-type-plan.md and
        // Documentation/output-tags-plan.md. `inline` joined this set
        // after real corpus evidence (`inline: -database=..., -sql=...;
        // ... /inline;`, no parens at all) showed it hitting the exact
        // same gap — see Documentation/outstanding-compatibility-project-plans.md.
        // `records`/`rows`'s bare zero-arg form (real corpus:
        // includes/detail_a_sku.lasso's bare `records` ... `/records`) is
        // the only shape reachable here for those two names — a
        // parenthesized `records(...)` would already have been consumed by
        // `parseBlockOpening` before `emitStatement` ever runs — so there's
        // no real form ambiguity for this switch to guard against the way
        // `parseIfOpening` genuinely has for "if"; a dedicated case here
        // would just re-produce what the generic case below already does.
        // `TagCatalog`'s `openForms` entry for `records`/`rows` still
        // documents `.bareIdentifier` as a supported form (useful data for
        // Phase 2), it just isn't separately dispatched here.
        switch expressions[0] {
        case let .call(.identifier(name), arguments) where TagCatalog.allowsBareOpen(name, in: .scriptBody):
            nodes.append(.tag(name: name, arguments: arguments, closing: false, dialect: .lasso8, range: statementRange))
        case let .identifier(name) where TagCatalog.allowsBareOpen(name, in: .scriptBody):
            nodes.append(.tag(name: name, arguments: [], closing: false, dialect: .lasso8, range: statementRange))
        default:
            nodes.append(.code(expressions, .lasso9, delimiter, statementRange))
        }
    }

    /// Translates a local offset into `characters` (this parser's own
    /// script-mode span) into an absolute `SourcePosition` in the whole
    /// document, anchored at `range.start` (this span's own starting
    /// position within that document).
    private func position(_ offset: Int) -> SourcePosition {
        var line = range.start.line
        var lastNewlineIndex: Int?
        let clampedOffset = min(offset, characters.count)
        for index in 0..<clampedOffset where characters[index] == "\n" {
            line += 1
            lastNewlineIndex = index
        }
        let column = lastNewlineIndex.map { clampedOffset - $0 } ?? range.start.column + clampedOffset
        return SourcePosition(offset: range.start.offset + clampedOffset, line: line, column: column)
    }


    private func normalizeReturn(_ statement: String) -> String {
        guard statement.lowercased().hasPrefix("return ") else { return statement }
        let value = statement.dropFirst("return ".count)
        return "return(\(value))"
    }

    private mutating func skipTrivia() {
        var moved = true
        while moved, index < characters.count {
            moved = false
            while index < characters.count, characters[index].isWhitespace {
                index += 1
                moved = true
            }
            if matches("//") {
                skipLineRemainder()
                moved = true
            } else if matches("/*") {
                index += 2
                while index + 1 < characters.count, !matches("*/") {
                    index += 1
                }
                index = min(index + 2, characters.count)
                moved = true
            }
        }
    }

    private mutating func skipHorizontalWhitespace() {
        while index < characters.count,
              characters[index] == " " || characters[index] == "\t" || characters[index] == "\r" {
            index += 1
        }
    }

    private mutating func skipLineRemainder() {
        while index < characters.count, characters[index] != "\n" {
            index += 1
        }
        if index < characters.count, characters[index] == "\n" {
            index += 1
        }
    }

    private mutating func readStatement() -> String {
        let start = index
        var parenDepth = 0
        var quote: Character?

        while index < characters.count {
            let character = characters[index]
            if let activeQuote = quote {
                index += 1
                if character == "\\" {
                    index = min(index + 1, characters.count)
                } else if character == activeQuote {
                    quote = nil
                }
                continue
            }

            if character == "'" || character == "\"" {
                quote = character
            } else if character == "(" {
                parenDepth += 1
            } else if character == ")" {
                parenDepth = max(parenDepth - 1, 0)
            } else if character == "}" {
                if parenDepth == 0 { break }
            } else if character == "\n", parenDepth == 0 {
                // A bare (unparenthesized) newline normally ends a
                // statement here — most script-mode code relies on that as
                // an implicit terminator, since trailing `;` is often
                // omitted. But real corpus bare colon-calls (`inline:
                // -database=...,\n -table=...,\n -sql='...' + \n '...';`,
                // one flag per line, no wrapping parens at all — see
                // Documentation/outstanding-compatibility-project-plans.md
                // item 4) span many physical lines with no paren depth to
                // keep them together. `grep`-counting every line ending
                // inside these real inline blocks confirmed exactly three
                // trailing characters mark "more follows on the next
                // line": the block-opener's own colon (`inline:`), a
                // trailing comma between arguments, and a trailing `+`
                // (string concatenation spanning lines) — every other
                // line ending was either a real statement end (`;`) or
                // inside an still-open quote (already handled above,
                // never reaches here). Continuing past the newline in
                // exactly these three cases (and no others) fixes the
                // multi-line shape without weakening the newline
                // terminator for ordinary one-statement-per-line code.
                if !Self.lineContinuesPastNewline(characters, start: start, upTo: index) {
                    break
                }
            }
            index += 1
        }

        let statement = String(characters[start..<index])
        if index < characters.count, characters[index] == "\n" {
            index += 1
        }
        return statement
    }

    /// True when the statement text accumulated so far (`characters[start..<upTo]`)
    /// ends, ignoring trailing horizontal whitespace, in `,`, `+`, or `:` —
    /// see the real-corpus-grounded explanation at `readStatement`'s call site.
    private static func lineContinuesPastNewline(_ characters: [Character], start: Int, upTo: Int) -> Bool {
        var i = upTo - 1
        while i >= start, characters[i] == " " || characters[i] == "\t" || characters[i] == "\r" {
            i -= 1
        }
        guard i >= start else { return false }
        return characters[i] == "," || characters[i] == "+" || characters[i] == ":"
    }

    /// Reads up to (not including) a case-insensitive, word-boundary match
    /// of `keyword` at paren-depth 0 outside any quote — used for `with
    /// name in <expression> do { ... }`, where the source expression has
    /// no delimiter of its own besides the following `do` keyword.
    private mutating func readUntilKeyword(_ keyword: String) -> String {
        let start = index
        var parenDepth = 0
        var quote: Character?

        while index < characters.count {
            let character = characters[index]
            if let activeQuote = quote {
                index += 1
                if character == "\\" {
                    index = min(index + 1, characters.count)
                } else if character == activeQuote {
                    quote = nil
                }
                continue
            }

            if character == "'" || character == "\"" {
                quote = character
            } else if character == "(" {
                parenDepth += 1
            } else if character == ")" {
                parenDepth = max(parenDepth - 1, 0)
            } else if parenDepth == 0, isKeywordBoundary(keyword, at: index) {
                break
            } else if character == "\n", parenDepth == 0 {
                break
            }
            index += 1
        }

        return String(characters[start..<index])
    }

    /// Reads a bare (paren-less) `if` condition up to, but not including,
    /// its terminating `{` or `=>` at paren-depth 0 outside any quote —
    /// leaving `index` positioned right at that terminator so the caller
    /// can hand off to `consumeArrowBlockStartIfPresent()` uniformly for
    /// both the `=> {` and bare `{` sub-shapes. Returns `nil` (and rewinds
    /// `index`) if a top-level newline or `;` is hit first, meaning this
    /// isn't actually the bare-brace-if shape.
    private mutating func readBareConditionBeforeBraceBody() -> String? {
        let start = index
        var parenDepth = 0
        var quote: Character?

        while index < characters.count {
            let character = characters[index]
            if let activeQuote = quote {
                index += 1
                if character == "\\" {
                    index = min(index + 1, characters.count)
                } else if character == activeQuote {
                    quote = nil
                }
                continue
            }

            if character == "'" || character == "\"" {
                quote = character
            } else if character == "(" {
                parenDepth += 1
            } else if character == ")" {
                parenDepth = max(parenDepth - 1, 0)
            } else if parenDepth == 0, character == "{" || matches("=>") {
                return String(characters[start..<index])
            } else if parenDepth == 0, character == "\n" || character == ";" {
                index = start
                return nil
            }
            index += 1
        }

        index = start
        return nil
    }

    /// True if `keyword` (case-insensitive) appears at `position` as a
    /// whole word — not as a prefix of a longer identifier on either side.
    private func isKeywordBoundary(_ keyword: String, at position: Int) -> Bool {
        let candidate = Array(keyword.lowercased())
        guard position + candidate.count <= characters.count else { return false }
        guard characters[position..<(position + candidate.count)].map({ Character($0.lowercased()) }) == candidate else {
            return false
        }
        if position > 0 {
            let previous = characters[position - 1]
            if previous.isLetter || previous.isNumber || previous == "_" { return false }
        }
        let after = position + candidate.count
        if after < characters.count {
            let next = characters[after]
            if next.isLetter || next.isNumber || next == "_" { return false }
        }
        return true
    }

    private mutating func readBalanced(open: Character, close: Character) -> String {
        guard index < characters.count, characters[index] == open else { return "" }
        index += 1
        let start = index
        var depth = 1
        var quote: Character?

        while index < characters.count, depth > 0 {
            let character = characters[index]
            if let activeQuote = quote {
                index += 1
                if character == "\\" {
                    index = min(index + 1, characters.count)
                } else if character == activeQuote {
                    quote = nil
                }
                continue
            }

            if character == "'" || character == "\"" {
                quote = character
            } else if character == open {
                depth += 1
            } else if character == close {
                depth -= 1
                if depth == 0 { break }
            }
            index += 1
        }

        let end = min(index, characters.count)
        if index < characters.count, characters[index] == close {
            index += 1
        } else {
            diagnostics.append(Diagnostic(message: "Unterminated '\(open)' ... '\(close)'", range: range))
        }
        return String(characters[start..<end])
    }

    /// Returns `true` if a brace body start (`"=> {"` or a bare `"{"`) was
    /// consumed, so the caller knows to track this block for later
    /// implicit closing by a bare `}` (see `openBraceBlockStack`).
    private mutating func consumeArrowBlockStartIfPresent() -> Bool {
        // Only same-line whitespace here, deliberately: this probe can
        // fail (a slash-style block has no '=>' at all), and on failure
        // the caller unconditionally calls skipLineRemainder() next. If
        // this skip crossed a newline while probing, that unconditional
        // call would then swallow the block body's first line instead of
        // just the block-opening line's own trailer. Once '=>' itself is
        // actually matched below, we're committed to arrow-brace mode and
        // multi-line skipping before '{' is safe.
        skipHorizontalWhitespace()
        if matches("=>") {
            index += 2
            skipTrivia()
        }
        if index < characters.count, characters[index] == "{" {
            index += 1
            return true
        }
        return false
    }

    private func parseCallArguments(name: String, body: String) -> [LassoArgument] {
        var parser = ExpressionParser("\(name)(\(body))")
        let expression = parser.parseExpression()
        guard case let .call(_, arguments) = expression else { return [] }
        return arguments
    }

    private mutating func readIdentifier() -> String {
        let start = index
        while index < characters.count,
              characters[index].isLetter || characters[index].isNumber || characters[index] == "_" {
            index += 1
        }
        return String(characters[start..<index])
    }

    /// Non-mutating lookahead: does an `else` keyword appear next, once
    /// trivia is skipped? Used by `parseIgnoredBrace` to decide whether a
    /// brace-style if's closing `}` should close it immediately or wait
    /// for a following else branch's own closing brace.
    private mutating func peekIsElseKeyword() -> Bool {
        let saved = index
        skipTrivia()
        let isElse = readKeyword("else")
        index = saved
        return isElse
    }

    private mutating func readKeyword(_ keyword: String) -> Bool {
        let start = index
        let identifier = readIdentifier()
        guard identifier.caseInsensitiveCompare(keyword) == .orderedSame else {
            index = start
            return false
        }
        return true
    }

    private func matches(_ text: String) -> Bool {
        let candidate = Array(text)
        guard index + candidate.count <= characters.count else { return false }
        return Array(characters[index..<(index + candidate.count)]) == candidate
    }
}
