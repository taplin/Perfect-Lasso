import Foundation

struct ScriptBodyParser {
    private let characters: [Character]
    private let range: SourceRange
    private let delimiter: LassoDelimiter
    private var index = 0
    private var nodes: [LassoNode] = []
    private(set) var diagnostics: [Diagnostic] = []
    /// Tag-open-form recognition counts, folded up from every nested
    /// `ScriptBodyParser`/`TypeBodyParser` this instance constructs (Phase 3
    /// of tag-form consolidation). Plain, unsynchronized local accumulation
    /// — this parser is a value type scoped to one parse call; the shared,
    /// locked, cross-request store only ever receives a batched merge, at
    /// the request boundary in `main.swift`, never a per-match write.
    private(set) var openFormFires: [TagOpenFormFire: Int] = [:]

    private mutating func recordFire(_ tagName: String, _ form: TagOpenForm) {
        openFormFires[TagOpenFormFire(tagName: tagName.lowercased(), form: form), default: 0] += 1
    }

    private mutating func mergeFires(from other: [TagOpenFormFire: Int]) {
        for (fire, count) in other {
            openFormFires[fire, default: 0] += count
        }
    }
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
        let colonConsumed = index < characters.count && characters[index] == ":"
        if colonConsumed {
            index += 1
            skipHorizontalWhitespace()
        }
        guard index < characters.count, characters[index] == "(" else {
            index = start
            return false
        }

        // Recorded whenever this tag has ANY documented open form at all
        // (not gated on the specific form matched) — deliberately a
        // broader net than "only count attested forms," so a real
        // colon-call on a tag the catalog currently lists as
        // `.parenCall`-only (e.g. a hypothetical `inline:(...)`) still
        // surfaces as a real sighting instead of being silently dropped.
        // Knowing about genuinely unsupported/unattested forms in real
        // corpus traffic is exactly as important as knowing how often the
        // documented ones fire (Phase 3 design decision).
        if !entry.openForms.isEmpty {
            recordFire(normalized, colonConsumed ? .colonCall : .parenCall)
        }

        let body = readBalanced(open: "(", close: ")")
        let arguments = parseCallArguments(name: name, body: body)
        // Only skip to the next line when no brace body was opened: once
        // `consumeArrowBlockStartIfPresent()` has consumed the body's own
        // opening `{`, we're positioned INSIDE that body, not on the
        // opener line's trailer — an unconditional `skipLineRemainder()`
        // here would blindly discard everything up to the next newline,
        // silently swallowing the entire body (and, for a single-line
        // `tag(...) => { ... }`, its closing `}` too) whenever the body
        // sits on the same line as the opener. Multi-line bodies never hit
        // this because the character right after `{` is already `\n`.
        if consumeArrowBlockStartIfPresent() {
            openBraceBlockStack.append(name)
        } else {
            skipLineRemainder()
        }
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
        /// Lasso 8's classic slash-closed colon-call with a bare condition
        /// — `if: cond; ... /if;`, no parens, no braces. Only reachable
        /// when a colon was consumed (see `readBareConditionBeforeSemicolon`'s
        /// doc comment) — a real corpus shape distinct from both cases
        /// above, closed later by `BlockBuilder`'s pairing pass matching
        /// this opener with a literal `/if`, same as `iterate:`/`while:`.
        case bareColonCall(String)
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

        // Only after the brace-body form has ruled itself out, and only
        // when a colon was actually consumed — every real corpus sighting
        // of this form is `if: cond;`, always colon-prefixed; requiring it
        // here avoids a bare `if cond` (no colon) with no brace/paren
        // ever reaching this classification, which would otherwise risk
        // swallowing unrelated bare expression statements that just
        // happen to start with the word "if" in some other shape.
        if colonConsumed, let condition = readBareConditionBeforeSemicolon() {
            let trimmedCondition = condition.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedCondition.isEmpty {
                return .bareColonCall(trimmedCondition)
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
            case .bareCondition, .bareIdentifier, .bareColonCall:
                preconditionFailure("classifyIfOpen's .parenOrColonCall case only ever carries .parenCall/.colonCall")
            }
            recordFire(name, form)
            let body = readBalanced(open: "(", close: ")")
            let arguments = parseCallArguments(name: name, body: body)
            // See the matching comment in `parseBlockOpening`: skipping to
            // the next line here is only correct when no brace body was
            // just opened — otherwise it silently swallows a single-line
            // `if(...) => { ... }` body (and its closing `}`) whole.
            if consumeArrowBlockStartIfPresent() {
                openBraceBlockStack.append(name)
            } else {
                skipLineRemainder()
            }
            nodes.append(.tag(name: name, arguments: arguments, closing: false, dialect: .lasso9, range: range))
            return true
        case let .bareCondition(trimmedCondition):
            // `classifyIfOpen` only ever returns `.bareCondition` after its
            // own `consumeArrowBlockStartIfPresent()` call already
            // succeeded (see that function's doc) — this case is always
            // reached already positioned inside the freshly-opened brace
            // body, so — unlike the sibling case above — there is no
            // "no brace body was opened" branch to fall back to here at
            // all; a `skipLineRemainder()` call in this case would
            // unconditionally swallow the body whole on a single-line
            // `if cond { ... }`, the same bug fixed above.
            recordFire(name, .bareCondition)
            openBraceBlockStack.append(name)
            var conditionParser = ExpressionParser(trimmedCondition)
            let conditionExpression = conditionParser.parseExpression()
            nodes.append(.tag(
                name: name,
                arguments: [LassoArgument(label: nil, value: conditionExpression)],
                closing: false,
                dialect: .lasso9,
                range: range
            ))
            return true
        case let .bareColonCall(trimmedCondition):
            // Slash-closed, not brace-closed — deliberately does NOT push
            // onto openBraceBlockStack (that stack is only for arrow/bare
            // brace bodies). BlockBuilder's existing pairing pass matches
            // this .tag(..., closing: false) opener with the real `/if`
            // closer already in the source, same mechanism iterate:/while:
            // rely on (Phase 4 of tag-form consolidation).
            recordFire(name, .bareColonCall)
            var conditionParser = ExpressionParser(trimmedCondition)
            let conditionExpression = conditionParser.parseExpression()
            skipLineRemainder()
            nodes.append(.tag(
                name: name,
                arguments: [LassoArgument(label: nil, value: conditionExpression)],
                closing: false,
                dialect: .lasso8,
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

        var name = readIdentifier()
        guard !name.isEmpty else {
            diagnostics.append(Diagnostic(message: "Malformed 'define': expected a tag name", range: range))
            index = start
            return false
        }
        skipHorizontalWhitespace()
        // Ch. "Types" > "Custom Getters and Setters": `public firstName=
        // (value) => {...}` -- a method NAME ending in `=`, called via
        // `#someone->firstName = "Bob"`. Real corpus (zeroloop/ds's
        // ds.lasso): `define ds_connections_closed = (p::integer) => ...`
        // (an UNBOUND, top-level setter-style tag, not a type member).
        // `!matches("==")`/`!matches("=>")` rule out equality and the
        // association operator -- a plain `define name => expr` never
        // reaches here with a bare trailing `=` otherwise, since ordinary
        // defines always use `=>`, never a lone `=`.
        if index < characters.count, characters[index] == "=", !matches("=="), !matches("=>") {
            index += 1
            name += "="
            skipHorizontalWhitespace()
        }

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
            mergeFires(from: typeParser.openFormFires)
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
        mergeFires(from: nestedParser.openFormFires)
        // parse() returns a flat open/close-tag stream — pairing it into
        // nested .block structures (if/loop/inline/etc.) is normally a
        // separate BlockBuilder pass that only runs at the top-level
        // LassoParser.parse() entry. Run it here too, since this body is
        // parsed independently of that entry point.
        var nestedBuilder = BlockBuilder(nodes: flatNestedBody, diagnostics: [], openFormFires: [:])
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
            // NOT a diagnostic-worthy failure: this exact shape (`with
            // NAME in SOURCE` followed by anything other than `do`) is
            // now ALSO the valid start of the expression-level Query
            // Expression's own `select` action (Stage 8.1) — e.g. `with
            // n in array(1,2,3) select #n * n`. Recording a "Malformed
            // with... expected 'do'" diagnostic here for perfectly
            // legitimate syntax would be actively misleading if a
            // developer debugging some UNRELATED real error in the same
            // request also sees this line in `document.diagnostics`.
            // Genuinely malformed input still gets real feedback: either
            // the fallback expression-level parse below also fails to
            // recognize it (falling back to a bare `with` identifier,
            // which then surfaces its own downstream error normally), or
            // it succeeds as a real query expression.
            index = start
            return false
        }
        skipTrivia()

        guard index < characters.count, characters[index] == "{" else {
            // Same reasoning as the `do`-keyword check above: `do EXPR`
            // (no braces) is now ALSO the valid bare-expression form of
            // the Query Expression `do` action (Stage 8.1) — e.g. `with
            // n in #ary do #n->upperCase`, the real docs' own worked
            // example. Not diagnostic-worthy for the same reason.
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
        // `^}` closes an auto-collect capture literal (`{^ ... ^}`) — see
        // `consumeArrowBlockStartIfPresent`'s matching comment. Checked
        // before the plain `}` case since `^` alone is never a valid
        // statement start here and would otherwise fall through to
        // `emitStatement`/the expression parser and fail as an
        // unsupported bare `^` token.
        if characters[index] == "^", index + 1 < characters.count, characters[index + 1] == "}" {
            index += 2
        } else if characters[index] == "}" {
            index += 1
        } else {
            return false
        }
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
        // Documentation/output-tags-plan.md. `iterate`/`while`/`protect`
        // joined this set in Phase 4 of tag-form consolidation, after
        // real corpus evidence (components/inSite/tables.inc's
        // `iterate: vars, local:'i'`, components/inSite/urlencode.inc's
        // `while: #url_string >> '++'`, _botscript.lasso's bare
        // `protect`) showed all three hitting the exact same gap
        // `inline` did before it — a real block-pairing bug, not just a
        // documentation gap (see TagCatalog.swift's Phase 4 note).
        // A parenthesized/colon-with-parens form (`records(...)`,
        // `if:(...)`) is already consumed by `parseBlockOpening` before
        // `emitStatement` ever runs, so there's no real form ambiguity for
        // this switch to guard against the way `parseIfOpening` genuinely
        // has for "if" — every name reaching either arm below has exactly
        // one real shape: a colon-call with arguments (`.bareColonCall`)
        // in the `.call` arm, or a bare zero-arg identifier
        // (`.bareIdentifier`) in the `.identifier` arm. Recording is
        // therefore unconditional within each arm (both are already gated
        // by `TagCatalog.allowsBareOpen`), not name-specific.
        switch expressions[0] {
        case let .call(.identifier(name), arguments) where TagCatalog.allowsBareOpen(name, in: .scriptBody):
            recordFire(name, .bareColonCall)
            nodes.append(.tag(name: name, arguments: arguments, closing: false, dialect: .lasso8, range: statementRange))
        case let .identifier(name) where TagCatalog.allowsBareOpen(name, in: .scriptBody):
            recordFire(name, .bareIdentifier)
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


    /// Rewrites a bare (paren-less) `return X`/`yield X` statement into
    /// `return(X)`/`yield(X)` before handing it to `ExpressionParser` --
    /// without this, a bare keyword followed directly by a value (no
    /// parens) parses via the generic juxtaposition/string-concatenation
    /// sugar (`parseJuxtaposedValueTrackingGiveback`: bare identifier
    /// `return`/`yield`, evaluating to an unrelated undefined variable,
    /// concatenated with whatever value follows) instead of ever calling
    /// the real `register("return")`/`register("yield")` native
    /// function at all. `yield` was missing here entirely until Stage 2
    /// (Captures) added a real `register("yield")` — found via a
    /// regression test (`{ yield 'hello' }`, invoked directly) that
    /// silently produced no output instead of "hello", while the
    /// identically-shaped `{ return 'hello' }` already worked correctly.
    private func normalizeReturn(_ statement: String) -> String {
        for keyword in ["return", "yield"] {
            let prefix = keyword + " "
            guard statement.lowercased().hasPrefix(prefix) else { continue }
            let value = statement.dropFirst(prefix.count)
            return "\(keyword)(\(value))"
        }
        return statement
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
        // A Capture literal (`{...}`/`{^...^}`) embedded in an ordinary
        // statement — e.g. `local(cap) = { ... }` or
        // `#ary->forEachPair => { ... }` (real corpus:
        // bugcity9/StartUpTags/AuthorizeNet_AIM_9.inc's
        // `#AIMParams->forEachPair => { #AIMParamArray->insert(...) }`).
        // Without tracking this, the FIRST `}` inside the capture's own
        // body would be mistaken for THIS statement's terminator,
        // truncating everything after it — this statement's raw text
        // must include the capture's entire body, unparsed, so
        // `ExpressionParser`'s own brace-balanced `readCaptureBody` can
        // later re-extract and parse it correctly (see that function's
        // own doc comment).
        var braceDepth = 0
        var quote: Character?

        while index < characters.count {
            let character = characters[index]
            if let activeQuote = quote {
                index += 1
                // Ch. "Literals" > "Ticked Strings": "the backslash
                // character holds no special meaning" inside a ticked
                // string, unlike quoted (single/double) strings where it
                // escapes the next character — a ticked span containing
                // a literal `\` must not skip the character after it
                // (found by architect + code-reviewer review of the
                // ticked-string investigation: without this guard, EVERY
                // raw-text quote-tracking scanner in this parser — not
                // just this one — desyncs on a ticked string containing
                // an unescaped structural character, e.g. a regex
                // pattern's own `]`/`)`/`}`, silently truncating the
                // enclosing bracket-tag/capture-body/statement).
                if character == "\\", activeQuote != "`" {
                    index = min(index + 1, characters.count)
                } else if character == activeQuote {
                    quote = nil
                }
                continue
            }

            if character == "'" || character == "\"" || character == "`" {
                quote = character
            } else if character == "(" {
                parenDepth += 1
            } else if character == ")" {
                parenDepth = max(parenDepth - 1, 0)
            } else if character == "{" {
                braceDepth += 1
            } else if character == "}" {
                if braceDepth > 0 {
                    braceDepth -= 1
                } else if parenDepth == 0 {
                    break
                }
            } else if character == "\n", parenDepth == 0, braceDepth == 0 {
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
                if !Self.lineContinuesPastNewline(characters, start: start, upTo: index),
                   !Self.nextLineStartsWithTernaryOperator(characters, from: index) {
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

    /// Real corpus (zeroloop/ds's activerow.lasso): a ternary's condition
    /// and its leading `?` sometimes sit on SEPARATE physical lines --
    /// `::json_encode->istype` / `? define json_encode->encodeValue(...) => ...`
    /// -- an "operator-led continuation" style distinct from the three
    /// trailing-character cases `lineContinuesPastNewline` above covers
    /// (which all look BACKWARD at the current line's own end). This looks
    /// FORWARD instead: a bare `?` or `|` (the ternary's condition/else
    /// separators -- `cond ? whenTrue | whenElse`) as the first
    /// non-whitespace character on the very next line means the PREVIOUS
    /// line's statement isn't actually finished yet. Neither token is
    /// otherwise a valid statement-starter in this language, so this is
    /// unambiguous regardless of whether a lone `|` happens to be the
    /// first half of a `||` compound token.
    private static func nextLineStartsWithTernaryOperator(_ characters: [Character], from newlineIndex: Int) -> Bool {
        var i = newlineIndex + 1
        while i < characters.count, characters[i] == " " || characters[i] == "\t" || characters[i] == "\r" {
            i += 1
        }
        return i < characters.count && (characters[i] == "?" || characters[i] == "|")
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
                // Ch. "Literals" > "Ticked Strings": "the backslash
                // character holds no special meaning" inside a ticked
                // string, unlike quoted (single/double) strings where it
                // escapes the next character — a ticked span containing
                // a literal `\` must not skip the character after it
                // (found by architect + code-reviewer review of the
                // ticked-string investigation: without this guard, EVERY
                // raw-text quote-tracking scanner in this parser — not
                // just this one — desyncs on a ticked string containing
                // an unescaped structural character, e.g. a regex
                // pattern's own `]`/`)`/`}`, silently truncating the
                // enclosing bracket-tag/capture-body/statement).
                if character == "\\", activeQuote != "`" {
                    index = min(index + 1, characters.count)
                } else if character == activeQuote {
                    quote = nil
                }
                continue
            }

            if character == "'" || character == "\"" || character == "`" {
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
                // Ch. "Literals" > "Ticked Strings": "the backslash
                // character holds no special meaning" inside a ticked
                // string, unlike quoted (single/double) strings where it
                // escapes the next character — a ticked span containing
                // a literal `\` must not skip the character after it
                // (found by architect + code-reviewer review of the
                // ticked-string investigation: without this guard, EVERY
                // raw-text quote-tracking scanner in this parser — not
                // just this one — desyncs on a ticked string containing
                // an unescaped structural character, e.g. a regex
                // pattern's own `]`/`)`/`}`, silently truncating the
                // enclosing bracket-tag/capture-body/statement).
                if character == "\\", activeQuote != "`" {
                    index = min(index + 1, characters.count)
                } else if character == activeQuote {
                    quote = nil
                }
                continue
            }

            if character == "'" || character == "\"" || character == "`" {
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

    /// The mirror image of `readBareConditionBeforeBraceBody`: real corpus
    /// Lasso 8 also writes `if` as a classic slash-closed colon-call with a
    /// bare (paren-less) condition — `if: error_currenterror!='No error';
    /// ... /if;` (importscripts/ca_web.lasso and 17 other real pages) —
    /// distinct from both the paren form and the brace-body form above.
    /// Quote/paren-depth-aware scan identical to that function's, but with
    /// the termination logic inverted: `;`/newline at depth 0 is the
    /// expected end of the condition (returns the text), while `{`/`=>`
    /// means this is actually the brace-body form and this function isn't
    /// the right match (rewind, return `nil`) — `classifyIfOpen` tries
    /// `readBareConditionBeforeBraceBody` first for exactly this reason, so
    /// this one only ever runs once that has already ruled itself out.
    private mutating func readBareConditionBeforeSemicolon() -> String? {
        let start = index
        var parenDepth = 0
        var quote: Character?

        while index < characters.count {
            let character = characters[index]
            if let activeQuote = quote {
                index += 1
                // Ch. "Literals" > "Ticked Strings": "the backslash
                // character holds no special meaning" inside a ticked
                // string, unlike quoted (single/double) strings where it
                // escapes the next character — a ticked span containing
                // a literal `\` must not skip the character after it
                // (found by architect + code-reviewer review of the
                // ticked-string investigation: without this guard, EVERY
                // raw-text quote-tracking scanner in this parser — not
                // just this one — desyncs on a ticked string containing
                // an unescaped structural character, e.g. a regex
                // pattern's own `]`/`)`/`}`, silently truncating the
                // enclosing bracket-tag/capture-body/statement).
                if character == "\\", activeQuote != "`" {
                    index = min(index + 1, characters.count)
                } else if character == activeQuote {
                    quote = nil
                }
                continue
            }

            if character == "'" || character == "\"" || character == "`" {
                quote = character
            } else if character == "(" {
                parenDepth += 1
            } else if character == ")" {
                parenDepth = max(parenDepth - 1, 0)
            } else if parenDepth == 0, character == "{" || matches("=>") {
                index = start
                return nil
            } else if parenDepth == 0, character == ";" {
                let condition = String(characters[start..<index])
                index += 1
                return condition
            } else if parenDepth == 0, character == "\n" {
                let condition = String(characters[start..<index])
                return condition
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
                // Ch. "Literals" > "Ticked Strings": "the backslash
                // character holds no special meaning" inside a ticked
                // string, unlike quoted (single/double) strings where it
                // escapes the next character — a ticked span containing
                // a literal `\` must not skip the character after it
                // (found by architect + code-reviewer review of the
                // ticked-string investigation: without this guard, EVERY
                // raw-text quote-tracking scanner in this parser — not
                // just this one — desyncs on a ticked string containing
                // an unescaped structural character, e.g. a regex
                // pattern's own `]`/`)`/`}`, silently truncating the
                // enclosing bracket-tag/capture-body/statement).
                if character == "\\", activeQuote != "`" {
                    index = min(index + 1, characters.count)
                } else if character == activeQuote {
                    quote = nil
                }
                continue
            }

            // Real corpus (zeroloop/ds's ds.lasso): `// Don't store
            // connections...` -- see `TypeBodyParser.readBalanced`'s
            // identical fix/comment for the full failure mode (an
            // apostrophe inside a `//`/`/* */` comment was previously
            // mistaken for an opening string quote, desyncing balance-
            // tracking and silently swallowing everything up to the next
            // apostrophe anywhere later in the source).
            if character == "/", index + 1 < characters.count, characters[index + 1] == "/" {
                while index < characters.count, characters[index] != "\n" { index += 1 }
                continue
            }
            if character == "/", index + 1 < characters.count, characters[index + 1] == "*" {
                index += 2
                while index + 1 < characters.count, !(characters[index] == "*" && characters[index + 1] == "/") {
                    index += 1
                }
                index = min(index + 2, characters.count)
                continue
            }

            if character == "'" || character == "\"" || character == "`" {
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
            // `{^ ... ^}` (Ch. "Captures": an auto-collect capture literal)
            // is real, documented Lasso 9 syntax real corpus attaches to
            // these same TagCatalog block keywords (`inline(...)=>{^ ... ^}`
            // is TS_lasso9's near-universal shape for an inline's content
            // block). For a TagCatalog block tag, the body is always
            // rendered as template content via `Renderer.render(body)` —
            // there is no separate capture object whose auto-collected
            // return value could ever be consumed — so auto-collect vs.
            // plain is not a real distinction here; the `^` marker just
            // needs to be tolerated (consumed, not treated as the start of
            // an ordinary statement) rather than given new runtime
            // semantics. The matching closer's own `^` (before `}`) is
            // handled symmetrically by `parseIgnoredBrace`.
            if index < characters.count, characters[index] == "^" {
                index += 1
            }
            return true
        }
        return false
    }

    private func parseCallArguments(name: String, body: String) -> [LassoArgument] {
        // A fixed placeholder callee, not `name` itself -- see
        // `TypeBodyParser.parseCallArguments`'s identical fix/comment: a
        // setter-style name ending in `=` would otherwise reconstruct as
        // an ASSIGNMENT (`name = (body)`) rather than a call.
        var parser = ExpressionParser("__scriptBodyParserParams__(\(body))")
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

    /// Non-mutating lookahead: does an `else` keyword appear next, AND
    /// does that else clause itself continue as an arrow/brace body
    /// (`else`, optionally `(condition)`, then `=>{` or bare `{`)? Used by
    /// `parseIgnoredBrace` to decide whether a brace-style if's closing
    /// `}` should close it immediately or wait for a following else
    /// branch's own closing brace to finally pop it.
    ///
    /// Checking only for a bare `else` keyword (as this used to) isn't
    /// enough: a plain, slash-closed else belonging to an OUTER,
    /// differently-nested if looks identical from here (e.g. `if(cond)
    /// ... else if(x)=>{...} else 'plain' /if`, where the inner arrow-if
    /// has no else of its own). Deferring the inner if's close in that
    /// case leaves it permanently unpopped — `BlockBuilder`'s later flat
    /// re-nesting pass then greedily attaches the OUTER if's real else
    /// (and its own closing `/if`) to this inner if instead, silently
    /// truncating the outer if's body and losing everything meant to
    /// follow it. Requiring the else clause to ALSO open with
    /// `=>{`/bare `{` here is what disambiguates "this else really is
    /// this arrow-if's own" from "this else belongs to some enclosing,
    /// differently-styled if that just happens to sit right after my
    /// closing brace." Real corpus:
    /// includes/efs_process.lasso's PayPal branch — a self-contained,
    /// else-less `if(...)=>{ ... }` nested inside a larger
    /// if(gift)/else(if(invoice)/else(paypal)/else(creditcard)/if)
    /// chain — silently dropped the entire Credit Card branch (and
    /// everything in the file after it) before this fix.
    private mutating func peekIsElseKeyword() -> Bool {
        let saved = index
        defer { index = saved }
        skipTrivia()
        guard readKeyword("else") else { return false }
        skipHorizontalWhitespace()
        if index < characters.count, characters[index] == "(" {
            _ = readBalanced(open: "(", close: ")")
            skipHorizontalWhitespace()
        }
        return consumeArrowBlockStartIfPresent()
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
