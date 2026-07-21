private enum Token: Equatable {
    case identifier(String)
    case variable(String, VariableScope)
    case string(String)
    case integer(Int)
    case decimal(Double)
    case named(String)
    case symbol(String)
    /// `\identifier` — a bareword reference to an already-defined tag
    /// (Ch. 30 Table 21, `\Compare_LessThan`), NOT a call. Confirmed no
    /// collision: the only other `\` handling anywhere in this parser is
    /// INSIDE quoted-string escape sequences (`readString`, entirely
    /// separate from this top-level lexer dispatch); a bare top-level `\`
    /// previously fell through to `.symbol("\\")` with no grammar
    /// production matching it, so this is purely additive.
    case tagReference(String)
    /// A Lasso 9 Capture literal's raw, unparsed body text — `{ ... }`
    /// (regular) or `{^ ... ^}` (auto-collect). Extracted by a brace-
    /// balanced, quote-aware scan directly on the source text (mirroring
    /// `ScriptBodyParser.readBalanced`, since generic single-character
    /// tokenizing can't correctly find the matching close without it —
    /// see `Captures.swift`'s own doc comment). Parsed into `[LassoNode]`
    /// by `ExpressionParser.parsePrefix()`, not here — the lexer has no
    /// access to `ScriptBodyParser`/`BlockBuilder`'s node-tree machinery.
    case captureBody(source: String, autoCollect: Bool)
    case eof
}

private struct ExpressionLexer {
    let characters: [Character]
    var index = 0

    init(_ source: String) {
        characters = Array(source)
    }

    mutating func lex() -> [Token] {
        var tokens: [Token] = []
        while let token = next() { tokens.append(token) }
        tokens.append(.eof)
        return tokens
    }

    mutating private func next() -> Token? {
        skipTrivia()
        guard index < characters.count else { return nil }
        let character = characters[index]

        if character == "'" || character == "\"" { return .string(readString(character)) }
        if character.isNumber { return readNumber() }
        // A leading-dot decimal literal (`.01`, `.5`) -- real Lasso allows
        // omitting the integer part before the point. Without this, a bare
        // `.` here is indistinguishable from Lasso's `.methodName`
        // self-shorthand member access (parsePrimary's `.symbol(".")`
        // case, `.member(base: self, name: ...)`), which happily accepts
        // ANY next token as the "member name" including a stray number,
        // producing a nonsense `.member(self, "<unknown>")` node. Member
        // names never start with a digit, so peeking one character ahead
        // cleanly disambiguates the two: real corpus
        // includes/efs_process.lasso's `math_round(field('order_grandtotal'),
        // .01)` was hitting exactly this collision.
        if character == ".", index + 1 < characters.count, characters[index + 1].isNumber { return readNumber() }
        if character == "$" || character == "#" {
            index += 1
            return .variable(readIdentifier(), character == "$" ? .global : .local)
        }
        if character == "-", index + 1 < characters.count, characters[index + 1].isLetter {
            index += 1
            return .named(readIdentifier())
        }
        if character == "\\", index + 1 < characters.count,
           characters[index + 1].isLetter || characters[index + 1] == "_" {
            index += 1
            return .tagReference(readIdentifier())
        }
        if character.isLetter || character == "_" { return .identifier(readIdentifier()) }
        if character == "{" { return readCaptureBody() }

        // Compound assignment (`+=`/`-=`/`*=`/`/=`) — real corpus: hundreds
        // of `$html += '...'`-shaped accumulator statements across the
        // detail/cart pages (e.g. includes/detail_a_sku.lasso), previously
        // lexed as separate `+`/`=` tokens, which broke parsing outright
        // (a bare `=` with nothing before it is not a valid expression on
        // its own) and silently dropped large chunks of built-up page HTML.
        for op in ["->", "==", "!=", ">=", "<=", "&&", "||", "::", "=>", ">>", "+=", "-=", "*=", "/="] where matches(op) {
            index += op.count
            return .symbol(op)
        }
        index += 1
        return .symbol(String(character))
    }

    mutating private func skipTrivia() {
        while index < characters.count {
            if characters[index].isWhitespace || characters[index] == ";" {
                index += 1
            } else if matches("//") {
                while index < characters.count, characters[index] != "\n" { index += 1 }
            } else if matches("/*") {
                index += 2
                while index + 1 < characters.count, !matches("*/") { index += 1 }
                index = min(index + 2, characters.count)
            } else {
                break
            }
        }
    }

    mutating private func readString(_ quote: Character) -> String {
        index += 1
        var value = ""
        while index < characters.count {
            let character = characters[index]
            index += 1
            if character == quote { break }
            if character == "\\", index < characters.count {
                // Real Lasso string literals support the standard `\n`/
                // `\t`/`\r` control-character escapes, not just "escape
                // the quote character" (`\'`/`\"`) — anything else
                // (including those) is literal, matching the previous
                // behavior. Found live: real corpus (e.g.
                // includes/detail_a_sku.lasso) builds page HTML with
                // string literals like `'...\n|<br>|...'`, relying on
                // `\n` being an actual newline (invisible in HTML output)
                // — treating it as literal "drop the backslash, keep the
                // letter n" instead inserted a visible, spurious "n"
                // wherever one of these appeared.
                switch characters[index] {
                case "n": value.append("\n")
                case "t": value.append("\t")
                case "r": value.append("\r")
                default: value.append(characters[index])
                }
                index += 1
            } else {
                value.append(character)
            }
        }
        return value
    }

    mutating private func readIdentifier() -> String {
        let start = index
        while index < characters.count,
              characters[index].isLetter || characters[index].isNumber || characters[index] == "_" {
            index += 1
        }
        return String(characters[start..<index])
    }

    /// Extracts a Capture literal's raw body text via a brace-balanced,
    /// quote-aware scan directly on the source characters — mirroring
    /// `ScriptBodyParser.readBalanced`'s own quote-escape handling, since
    /// the body can legitimately contain nested `{...}` (a capture
    /// literal inside another) and string literals with unrelated `{`/`}`
    /// characters inside them. `{^...^}` (auto-collect) is distinguished
    /// only by a leading `^` right after `{` and a trailing `^` right
    /// before the matching `}` — plain brace-depth counting on `{`/`}`
    /// alone already finds the correct matching close for both forms
    /// (the `^` characters never affect that balance), so no separate
    /// delimiter-matching logic is needed beyond stripping those two
    /// marker characters from the extracted body.
    mutating private func readCaptureBody() -> Token {
        index += 1 // consume "{"
        let autoCollect = index < characters.count && characters[index] == "^"
        if autoCollect { index += 1 }
        let bodyStart = index
        var depth = 1
        var quote: Character?
        var closedProperly = false
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
                index += 1
            } else if character == "{" {
                depth += 1
                index += 1
            } else if character == "}" {
                depth -= 1
                index += 1
                if depth == 0 {
                    closedProperly = true
                    break
                }
            } else {
                index += 1
            }
        }
        var bodyEnd = closedProperly ? index - 1 : index
        if autoCollect, bodyEnd > bodyStart, characters[bodyEnd - 1] == "^" {
            bodyEnd -= 1
        }
        return .captureBody(source: String(characters[bodyStart..<max(bodyEnd, bodyStart)]), autoCollect: autoCollect)
    }

    mutating private func readNumber() -> Token {
        let start = index
        var hasDecimal = false
        while index < characters.count {
            if characters[index] == ".", !hasDecimal {
                hasDecimal = true
                index += 1
            } else if characters[index].isNumber {
                index += 1
            } else {
                break
            }
        }
        let value = String(characters[start..<index])
        return hasDecimal ? .decimal(Double(value) ?? 0) : .integer(Int(value) ?? 0)
    }

    private func matches(_ text: String) -> Bool {
        let candidate = Array(text)
        guard index + candidate.count <= characters.count else { return false }
        return Array(characters[index..<(index + candidate.count)]) == candidate
    }
}

struct ExpressionParser {
    private let tokens: [Token]
    private var index = 0

    /// How many `parseArguments` calls — BARE (`closing == nil`) *or*
    /// WRAPPED (`Foo(...)`, `closing == ")"`) — are currently active, one
    /// inside another. Used by `parseArguments` to know whether an
    /// upcoming `)` genuinely, safely terminates THIS SPECIFIC bare call
    /// (only true when NO call frame of either kind currently encloses
    /// it) or merely terminates some ANCESTOR call's own wrap (depth > 0
    /// on entry) — see `parseArguments`'s own doc comment for why this
    /// distinction is load-bearing. Both kinds of frame must count: a
    /// bare colon-call nested directly inside an ordinary WRAPPED call's
    /// argument — e.g. `Identity($arr->get:1->first)` — sees `get:`'s own
    /// upcoming `)` as belonging to `Identity`'s wrap, not to `get`
    /// itself, and only a depth count that also tracks wrapped frames
    /// can tell the two apart. Found by architect re-verification via a
    /// real failing trace: counting bare frames only let `get:` in that
    /// example wrongly believe itself outermost, since `Identity(...)`'s
    /// own wrapped `parseArguments` call never touched the counter.
    /// Incremented/decremented with `defer` around EVERY `parseArguments`
    /// call regardless of `closing`, the same safe save/restore
    /// discipline the original, now-removed `suppressArrowPostfix` field
    /// always used correctly (that field's own problem was being too
    /// BROAD in scope, never a staleness/restore bug) — unlike the
    /// UNSCOPED `giveback` value itself, which is threaded through return
    /// values specifically BECAUSE an earlier draft's attempt to track it
    /// via a similar always-restored instance field still leaked (see
    /// `ArrowGiveback`'s own doc comment). A plain depth counter has no
    /// such risk: it carries no parse-result payload to go stale, only a
    /// nesting count that's always correctly restored on every exit path.
    private var enclosingCallArgumentListDepth = 0

    /// A bare colon-call (`closing == nil` in `parseArguments`) has no
    /// closing delimiter of its own — per the Lasso 8.5 Language Guide's
    /// "Colon Syntax" section (Ch. 4, Table 1's own worked example:
    /// `Tag_Name: Parameter_1, Sub_Tag: Parameter_2, Parameter_3` resolves
    /// as `Tag_Name: Parameter_1, (Sub_Tag: Parameter_2), Parameter_3` —
    /// "the outermost tag is greedy"), a `->`-chain trailing an argument's
    /// value can be genuinely ambiguous between "part of this argument" and
    /// "part of the whole call's result": `$arr->get:2->first` must parse
    /// as `($arr->get:2)->first`, not `$arr->get:(2->first)` (which
    /// crashes — `2` has no `first` member).
    ///
    /// Resolved by parsing GREEDILY (every argument's `->` chain is always
    /// consumed normally, no suppression) and then, in `parseArguments`,
    /// GIVING BACK the trailing chain if it turns out ambiguous — i.e. only
    /// when: the argument list is genuinely bare (`closing == nil`), the
    /// chain was applied directly onto a non-parenthesized base (a
    /// parenthesized base like `('abe')->SubString(1,1)` is never
    /// ambiguous — the parens themselves already scope it), AND neither a
    /// comma (proving more arguments follow, so the chain unambiguously
    /// belongs to what's already been parsed — matches the Guide's own
    /// "up to the next comma" reading) nor a `)` (an enclosing wrap's own
    /// boundary, which the chain can never reach past) follows. Only in
    /// that specific, genuinely-ambiguous circumstance is the chain's
    /// starting position rewound and handed back to the ENCLOSING postfix
    /// parse. This generalizes the fix beyond the original bare-integer-
    /// literal case above to any non-parenthesized base (a variable, a
    /// call result, etc.) — e.g. `(Compare_LessThan: $x->SubString(1,1),
    /// 'bob')` now correctly binds `->SubString(1,1)` to `$x` (a comma
    /// follows, unambiguous), while `$arr->get:2->first` still correctly
    /// binds `->first` to the call's result (nothing safe follows the bare
    /// `2->first`, ambiguous).
    ///
    /// **Threaded through return values, deliberately NOT a shared mutable
    /// instance field**: an earlier version of this fix used exactly such
    /// a field (`lastArrowStepGiveback: ArrowGiveback?`, set by
    /// `parsePostfix`, read by `parseArguments`) and shipped a real
    /// regression — `TypeBodyParser`'s recursive descent through nested
    /// tag bodies (e.g. `(self->'ticks') = (self->'ticks') + 1` inside a
    /// `Define_Tag` body, itself inside a `Define_Type` body) left STALE
    /// giveback state from one nested parse bleeding into an unrelated
    /// LATER `parseArguments` call's own check, since nothing scoped the
    /// field correctly across recursive `parseArguments`/`parseExpression`
    /// calls (mirroring exactly the save/restore discipline the ORIGINAL,
    /// now-removed `suppressArrowPostfix` field needed for the same
    /// reason). Threading `ArrowGiveback?` through `parsePrefix`/
    /// `parsePostfix`/`parseExpression`/`parseJuxtaposedValue`'s own
    /// TRACKING variants instead makes this a non-issue by construction —
    /// there's no shared state left to go stale. Real corpus (`->get:1`-
    /// style calls, 70+ sites) never puts a `->` inside a bare colon-call's
    /// own argument, so none of this changes behavior real code relies on.
    private typealias ArrowGiveback = (indexBeforeArrow: Int, expressionBeforeArrow: LassoExpression)

    init(_ source: String) {
        var lexer = ExpressionLexer(source)
        tokens = lexer.lex()
    }

    mutating func parseList() -> [LassoExpression] {
        var expressions: [LassoExpression] = []
        while peek != .eof {
            let start = index
            expressions.append(parseExpression())
            if start == index { index += 1 }
            _ = consume(",")
        }
        return expressions
    }

    mutating func parseExpression(minimumPrecedence: Int = 0) -> LassoExpression {
        parseExpressionTrackingGiveback(minimumPrecedence: minimumPrecedence).expression
    }

    /// See `ArrowGiveback`'s own doc comment. `giveback` only survives
    /// this function's own binary/`::`/ternary logic untouched (reset to
    /// `nil` the instant any of it fires) — it's ONLY non-`nil` when this
    /// call's entire result is exactly, unmodified, whatever the initial
    /// `parsePrefixTrackingGiveback()` call produced, which is the only
    /// circumstance `parseArguments` can safely act on it (see
    /// `isPostfixChainShape`'s own doc comment for why that's checked
    /// again there too, as a second, independent guard).
    mutating private func parseExpressionTrackingGiveback(
        minimumPrecedence: Int = 0
    ) -> (expression: LassoExpression, giveback: ArrowGiveback?) {
        var (left, giveback) = parsePrefixTrackingGiveback()
        while consume("::") {
            left = .binary(left: left, operator: "::", right: parseTypeConstraint())
            giveback = nil
        }
        while case let .symbol(op) = peek,
              let precedence = Self.precedence[op],
              precedence >= minimumPrecedence {
            index += 1
            let isAssignment = op == "=" || Self.compoundAssignmentOperators[op] != nil
            let right = parseExpression(minimumPrecedence: precedence + (isAssignment ? 0 : 1))
            if op == "=" {
                left = .assignment(target: left, value: right)
            } else if let baseOperator = Self.compoundAssignmentOperators[op] {
                left = .assignment(target: left, value: .binary(left: left, operator: baseOperator, right: right))
            } else {
                left = .binary(left: left, operator: op, right: right)
            }
            giveback = nil
        }
        // Lasso 8's `condition ? whenTrue | whenFalse` conditional-expression
        // operator — not a binary operator (not in `precedence`, and its
        // `|` separator would collide with bitwise/other single-`|` use if
        // it were). Bound looser than everything above: only recognized
        // starting a fresh top-level expression (`minimumPrecedence == 0`),
        // never mid-recursion for a binary operator's right-hand side, so
        // `left` here is the FULL condition already parsed at normal
        // precedence, matching the real corpus's exclusive usage as a
        // complete value expression (e.g. a call argument), not nested
        // inside a larger binary/assignment expression.
        if minimumPrecedence == 0, consume("?") {
            let whenTrue = parseExpression()
            if consume("|") {
                let whenFalse = parseExpression()
                left = .ternary(condition: left, whenTrue: whenTrue, whenFalse: whenFalse)
            } else {
                // Lasso 8's bare statement-guard form — `condition ?
                // statement`, no `|` branch at all (a separate dialect from
                // the value form above; real corpus: Auto_Record.inc,
                // mini_cart_tag.inc, pages/subcats.page.lasso's repeated
                // `[string($cid) != '' ? $bottom_cat=$cid]`). Previously this
                // fell through to unconditionally parsing a whenFalse that
                // was never there, consuming past the end of the bracket
                // body and producing an empty `unsupportedExpression("")`.
                // When false, the guard contributes nothing — `.void`
                // matches that; there's no real "else" value in this form.
                left = .ternary(condition: left, whenTrue: whenTrue, whenFalse: .void)
            }
            giveback = nil
        }
        return (left, giveback)
    }

    mutating private func parsePrefix() -> LassoExpression {
        parsePrefixTrackingGiveback().expression
    }

    /// See `ArrowGiveback`'s own doc comment for the overall mechanism.
    /// Every case here is giveback-ELIGIBLE (a bare, non-parenthesized
    /// base) except `.symbol("(")`, which produces an already self-
    /// contained, unambiguous group that never needs its own trailing
    /// chain given back.
    mutating private func parsePrefixTrackingGiveback() -> (expression: LassoExpression, giveback: ArrowGiveback?) {
        var expression: LassoExpression
        var eligibleForGiveback = true
        switch advance() {
        case let .string(value): expression = .string(value)
        case let .integer(value): expression = .integer(value)
        case let .decimal(value): expression = .decimal(value)
        case let .variable(name, scope): expression = .variable(name, scope)
        case let .tagReference(name): expression = .tagReference(name)
        case let .identifier(name):
            switch name.lowercased() {
            case "true": expression = .boolean(true)
            case "false": expression = .boolean(false)
            case "null" where peek == .symbol("(") || peek == .symbol(":"):
                // `null(expr)` / `[Null: expr]` — the Language Guide's own
                // canonical Iterator idiom (Ch. 30 pp.422-426, e.g.
                // `Null: $myIterator->Forward;`) calling the `null` free
                // function to evaluate-but-suppress-output an expression.
                // Bare `null` (no following call syntax) still falls
                // through to the `.null` literal below, so `x == null`
                // is unaffected.
                expression = .identifier(name)
            case "null": expression = .null
            case "void": expression = .void
            case "not": expression = .unary(operator: "not", value: parseExpression(minimumPrecedence: 8))
            default: expression = .identifier(name)
            }
        case let .symbol(op) where ["!", "-", "+"].contains(op):
            expression = .unary(operator: op, value: parseExpression(minimumPrecedence: 8))
        case .symbol("."):
            expression = .member(base: .identifier("self"), name: readMemberName(), arguments: nil)
        case .symbol("("):
            expression = parseExpression()
            _ = consume(")")
            // Already a self-contained, unambiguous unit — see
            // `eligibleForGiveback`'s own doc comment above.
            eligibleForGiveback = false
        case let .named(name): expression = .unknown("-\(name)")
        case let .symbol(value): expression = .unknown(value)
        case let .captureBody(source, autoCollect):
            expression = Self.parseCaptureLiteral(source: source, autoCollect: autoCollect)
            // Already a self-contained, unambiguous unit, same reasoning
            // as the parenthesized-group case above.
            eligibleForGiveback = false
        case .eof: return (.unknown(""), nil)
        }
        return parsePostfixTrackingGiveback(expression, eligibleForGiveback: eligibleForGiveback)
    }

    /// Parses a Capture literal's already-extracted raw body text
    /// (`ExpressionLexer.readCaptureBody`) into `[LassoNode]`, via the
    /// SAME two-pass pipeline every other nested block body in this
    /// parser uses (`define X => {...}`'s own method body,
    /// `Ex_Square`-style type-body methods, etc.): a fresh
    /// `ScriptBodyParser` produces a flat open/close-tag stream, then a
    /// `BlockBuilder` pass re-nests it into real `.block`-shaped nodes.
    /// Nested diagnostics are discarded — `ExpressionParser` has no
    /// diagnostics-collection mechanism of its own to append them to
    /// (unlike `ScriptBodyParser`/`TypeBodyParser`, both of which already
    /// have one) — a disclosed, Stage 1 limitation: a malformed capture
    /// body's parse errors won't surface as a diagnostic, only as
    /// whatever downstream effect the malformed node tree produces at
    /// evaluation time.
    private static func parseCaptureLiteral(source: String, autoCollect: Bool) -> LassoExpression {
        let placeholderRange = SourceRange(
            start: SourcePosition(offset: 0, line: 0, column: 0),
            end: SourcePosition(offset: 0, line: 0, column: 0)
        )
        var nestedParser = ScriptBodyParser(source: source, range: placeholderRange)
        let flatBody = nestedParser.parse()
        var nestedBuilder = BlockBuilder(nodes: flatBody, diagnostics: [], openFormFires: [:])
        let nestedResult = nestedBuilder.build()
        return .captureLiteral(body: nestedResult.nodes, autoCollect: autoCollect)
    }

    /// Parses `initial`'s own postfix chain (`(...)`/`:...`/`->member`),
    /// greedily — no suppression. When `eligibleForGiveback` (only true for
    /// a bare, non-parenthesized `initial`), the FIRST `->`-triggered step
    /// applied records its own pre-state as the returned `giveback` (only
    /// the first: once any step has been applied, eligibility is cleared,
    /// so a `1->first->second` chain's giveback point — if it turns out
    /// ambiguous — rewinds all the way back to `1`, handing the WHOLE
    /// trailing chain to the enclosing postfix parse, not just its last
    /// segment). See `ArrowGiveback`'s own doc comment for why, and
    /// `parseArguments` for where the giveback actually gets applied.
    mutating private func parsePostfixTrackingGiveback(
        _ initial: LassoExpression, eligibleForGiveback: Bool
    ) -> (expression: LassoExpression, giveback: ArrowGiveback?) {
        var expression = initial
        var eligible = eligibleForGiveback
        var giveback: ArrowGiveback?
        while true {
            if consume("(") {
                expression = .call(callee: expression, arguments: parseArguments(closing: ")"))
                eligible = false
                // A call step (unlike a further `->member` step) already
                // resolves its OWN internal argument-boundary ambiguity,
                // if any — the result is a new, self-contained value, not
                // simply "a bare base with a naive trailing chain"
                // anymore. Any `giveback` captured from an EARLIER `->`
                // step in this same chain is now stale relative to the
                // NEW `expression` (it would rewind too far back, past
                // this call, corrupting an unrelated OUTER bare-call's
                // own argument — found by code review via a real
                // failing trace: `$arr->get:1->first` nested as another
                // bare call's sole trailing argument).
                giveback = nil
            } else if consume(":") {
                expression = .call(callee: expression, arguments: parseArguments(closing: nil))
                eligible = false
                giveback = nil // see the `consume("(")` branch's own comment just above.
            } else if peek == .symbol("->") {
                if eligible {
                    giveback = (index, expression)
                }
                eligible = false
                index += 1 // consume "->"
                let wrapped = consume("(")
                let name = readMemberName()
                let arguments: [LassoArgument]?
                if wrapped {
                    if consume(":") {
                        // `->(name: arg1, arg2)` — the colon-call form
                        // inside the wrap. Only one closing paren is ever
                        // expected here (the wrap's own), since there's
                        // no separate inner call to close first.
                        arguments = parseArguments(closing: ")")
                    } else if consume("(") {
                        // `->(name(arg1, arg2))` — real corpus's
                        // dominant wrapped shape (e.g.
                        // `$msg->(Replace('!','<br>'))`). Two closing
                        // parens follow: the inner call's own, then the
                        // wrap's. `finishWrappedMember()`'s old single
                        // `parseArguments(closing: ")")` call consumed
                        // only the *inner* call's closing paren (which
                        // incidentally produced the right argument list,
                        // since the inner call's own arguments are what
                        // real Lasso means here) and left the wrap's
                        // outer closing paren dangling — parsed as its
                        // own bogus top-level `.unknown(")")` expression
                        // by whatever came next, silently swallowed only
                        // because a single-expression-per-span
                        // assumption elsewhere discarded it unnoticed.
                        arguments = parseArguments(closing: ")")
                        _ = consume(")")
                    } else {
                        // `->(name)` — bare member access wrapped in
                        // parens, no call at all.
                        arguments = nil
                        _ = consume(")")
                    }
                } else {
                    arguments = consume("(") ? parseArguments(closing: ")") : nil
                }
                expression = .member(base: expression, name: name, arguments: arguments)
            } else if peek == .symbol("=>") {
                // The association operator — Ch. "Captures": "When using
                // the association operator (`=>`) to invoke an object by
                // passing it a capture, the capture is known as the
                // object's associated block or capture block." Real
                // Lasso is NOT `forEach`-specific here: `if`/`while`/
                // `loop`/`match`/`iterate`/`define` are ALSO documented
                // as "a method invoked with an associated capture
                // block" — this codebase already hardcodes `=>`
                // recognition for exactly those six keywords at the
                // ScriptBodyParser/TypeBodyParser character level (see
                // `consumeArrowBlockStartIfPresent`), entirely separate
                // from and unaffected by this general path. This is the
                // GENERAL case: any other call/member/identifier
                // expression followed by `=> {...}`/`=> {^...^}` — real
                // corpus: `bugcity9/StartUpTags/AuthorizeNet_AIM_9.inc`'s
                // `#AIMParams->forEachPair => { ... }`,
                // `TS_lasso9/index.lasso`'s
                // `inline(-host=..., -sql=...)=>{ records=>{...} }`.
                // Only reached AFTER the postfix loop above has already
                // consumed every `(`/`:`/`->` step, so this can never
                // collide with those six keywords' own, earlier,
                // character-level recognition.
                index += 1 // consume "=>"
                let capture = parsePrefix()
                expression = Self.foldAssociatedCapture(expression, capture)
                // Same reasoning as the `consume("(")`/`consume(":")`
                // branches above: this transformation makes `expression`
                // a new, self-contained value, so any earlier giveback
                // point is now stale relative to it.
                giveback = nil
                return (expression, giveback)
            } else {
                return (expression, giveback)
            }
        }
    }

    /// Folds a Capture literal supplied via `=>` into its associated
    /// call as a new trailing, unlabeled argument — real Lasso's own
    /// `givenBlock` keyword (how a method reads back the capture it was
    /// associated with) has no natural slot in this codebase's existing
    /// native-function/custom-tag call signatures, so Stage 1
    /// represents "this call has an associated capture block" the same
    /// way this codebase already represents every other "pass a callable
    /// reference as a value" case (`Match_Comparator(\TagName, ...)`,
    /// etc.) — as an ordinary argument a later stage's native
    /// implementations (`Array->forEach` etc.) can look for. A bare
    /// `.identifier` callee with no call syntax of its own (`myTag =>
    /// {...}`) is promoted to a real `.call` so the capture has
    /// somewhere to attach.
    private static func foldAssociatedCapture(_ callee: LassoExpression, _ capture: LassoExpression) -> LassoExpression {
        // Labeled "givenblock" (Ch. "Captures": "A method that receives
        // an associated block accesses it via the `givenBlock` keyword,
        // not a normal parameter"), NOT an ordinary unlabeled positional
        // argument — `Evaluator.extractGivenBlock`'s own doc comment has
        // the full reasoning (a real bug an earlier version of this fold
        // had: an unlabeled trailing argument can silently misbind into
        // an unrelated declared parameter, or be silently dropped
        // entirely, whenever the call site's own explicit argument count
        // doesn't exactly match the callee's declared parameter count).
        let captureArgument = LassoArgument(label: "givenblock", value: capture)
        switch callee {
        case let .call(innerCallee, arguments):
            return .call(callee: innerCallee, arguments: arguments + [captureArgument])
        case let .member(base, name, arguments):
            return .member(base: base, name: name, arguments: (arguments ?? []) + [captureArgument])
        case let .identifier(name):
            return .call(callee: .identifier(name), arguments: [captureArgument])
        default:
            // No real corpus shape found for `=>` attaching to anything
            // else (a plain value, a binary expression, etc.) — folds as
            // a single-argument call on the callee itself rather than
            // silently dropping the capture.
            return .call(callee: callee, arguments: [captureArgument])
        }
    }

    mutating private func parseTypeConstraint() -> LassoExpression {
        switch advance() {
        case let .identifier(name), let .string(name):
            return .identifier(name)
        default:
            return .unknown("<type>")
        }
    }

    mutating private func parseArguments(closing: String?) -> [LassoArgument] {
        var arguments: [LassoArgument] = []
        // See `enclosingCallArgumentListDepth`'s own doc comment. Computed
        // BEFORE incrementing: depth is still whatever it was set to by
        // any ENCLOSING call frame (bare or wrapped), so `== 0` here
        // genuinely means "no other call frame is currently active above
        // me" — I'm the outermost, and an upcoming `)` can only belong to
        // MY OWN immediate wrap (or none at all). A NESTED bare call
        // (e.g. `get:` triggered while parsing `Outer:`'s own still-open
        // argument, OR while parsing an ordinary WRAPPED call's argument
        // like `Identity(...)`) sees a non-zero depth here instead,
        // correctly disqualifying `)` from being treated as a safe
        // terminator for ITS OWN giveback check — that `)` might belong
        // to the enclosing call's wrap, arbitrarily far up, not to `get`
        // itself. Found by architect review via real failing traces:
        // `(Outer: $arr->get:2->first)` and `Identity($arr->get:1->first)`.
        let isOutermostBareArgumentList = closing == nil && enclosingCallArgumentListDepth == 0
        let previousDepth = enclosingCallArgumentListDepth
        enclosingCallArgumentListDepth += 1
        defer { enclosingCallArgumentListDepth = previousDepth }
        while peek != .eof {
            if let closing, consume(closing) { break }
            // A bare-colon-call's argument list (`closing == nil` — no
            // parens of its own to match) has no way to recognize its own
            // end other than running out of commas. A *trailing* comma
            // before a caller-level `)` — real corpus:
            // components/inSite/email_instances.inc's `(Array: 'a', 'b',
            // // commented-out element\n))` — leaves this loop having just
            // consumed that comma and continuing, about to try parsing `)`
            // itself as the next argument's value; `parsePrefix`'s
            // catch-all `case let .symbol(value): expression =
            // .unknown(value)` turns that into a bogus `.unknown(")")`,
            // surfacing as `unsupportedExpression(")")`. A stray `)` can
            // never start a real argument either way, so treat it as this
            // bare list's natural end and let the *caller's* own
            // `consume(")")` (already established for `(Array: ...)`-style
            // wraps) claim it instead.
            if closing == nil, peek == .symbol(")") { break }
            var label: String?
            if case let .named(name) = peek {
                index += 1
                label = name
                if !consume("=") {
                    arguments.append(LassoArgument(label: label, value: .boolean(true)))
                    if !consume(",") {
                        if let closing { _ = consume(closing) }
                        break
                    }
                    continue
                }
            }
            var (value, giveback) = parseJuxtaposedValueTrackingGiveback()
            // Give back an ambiguous trailing `->` chain — see
            // `ArrowGiveback`'s own doc comment for the full reasoning.
            // Only applies when: this is a genuinely bare (`closing ==
            // nil`) argument list; the just-parsed value's OWN outermost
            // shape is exactly what a `->`-chain step would produce
            // (`.member`/`.call`) — a second, independent guard beyond
            // `giveback` already being `nil` whenever a compound
            // expression (`.binary`/`.ternary`/etc.) wraps it (see
            // `parseExpressionTrackingGiveback`/`parseJuxtaposedValueTrack
            // ingGiveback`'s own reset-on-any-wrapping logic) — belt and
            // suspenders against ever discarding part of a compound
            // value; and neither a comma (proving more arguments follow —
            // the chain unambiguously belongs to what's already been
            // parsed) nor a `)` THIS SPECIFIC bare call's own immediate
            // wrap will consume follows. That last check is `peek ==
            // .symbol(")")` ONLY when `isOutermostBareArgumentList` — a
            // NESTED bare call (some ancestor bare call is still open
            // above this one) can never trust an upcoming `)` to be ITS
            // OWN boundary, since it might belong to that ancestor's wrap
            // arbitrarily far up (see `enclosingCallArgumentListDepth`'s
            // own doc comment).
            let upcomingCloseParenIsSafe = isOutermostBareArgumentList && peek == .symbol(")")
            if closing == nil,
               let giveback,
               isPostfixChainShape(value),
               peek != .symbol(","), !upcomingCloseParenIsSafe {
                index = giveback.indexBeforeArrow
                value = giveback.expressionBeforeArrow
            }
            arguments.append(LassoArgument(label: label, value: value))
            if !consume(",") {
                if let closing { _ = consume(closing) }
                break
            }
        }
        return arguments
    }

    private func isPostfixChainShape(_ expression: LassoExpression) -> Bool {
        switch expression {
        case .member, .call: true
        default: false
        }
    }

    /// Lasso 8's documented operator-less string concatenation (Language
    /// Guide Ch. 22, "Miscellaneous Shortcuts": `['Showing ' (Shown_Count)
    /// ' records of ' (Found_Count) ' found.']`) — adjacent primary
    /// expressions with no operator between them implicitly concatenate.
    /// At the top level this already works for free: `ScriptBodyParser`
    /// hands one already-`;`-bounded statement span to a fresh
    /// `ExpressionParser`, whose `parseList()` just returns each juxtaposed
    /// piece as its own top-level expression, and multiple top-level
    /// expressions already render as concatenated output (`.code(...)`'s
    /// existing behavior — the same mechanism a `<?LassoScript
    /// String(...); Field(...); String(...); ?>` sequence relies on). It
    /// breaks specifically *inside* one argument's value: `parseArguments`
    /// used to call `parseExpression()` exactly once per value, so
    /// `-SQL='...' #cat_master '...'` only captured the leading string —
    /// `#cat_master` and the trailing string spilled out as extra
    /// top-level expressions, which desynced the whole surrounding
    /// statement (`ScriptBodyParser.emitStatement` requires exactly one
    /// top-level expression to recognize a tag-opening call at all, so the
    /// spillover silently downgraded a real `inline: ...` block into a
    /// bare, unrecognized function call). Real corpus:
    /// components/inSite/filtered_links.inc's `-SQL='SELECT * FROM
    /// categories WHERE `cat_masters` LIKE "%' #cat_master '%"'`.
    /// Deliberately narrow about what can start a continuation — only
    /// strings, local/variable references, and parenthesized
    /// sub-expressions (covering the PDF's own `(Shown_Count)`-style
    /// wrapped-tag-call example) match real corpus/documented usage. A
    /// bare unparenthesized identifier is excluded on purpose: nothing in
    /// the doc or corpus juxtaposes one, and treating it as a
    /// continuation would risk swallowing what's actually the *next*
    /// statement into this argument's value.
    mutating private func parseJuxtaposedValue() -> LassoExpression {
        parseJuxtaposedValueTrackingGiveback().value
    }

    mutating private func parseJuxtaposedValueTrackingGiveback() -> (value: LassoExpression, giveback: ArrowGiveback?) {
        var (value, giveback) = parseExpressionTrackingGiveback()
        while startsJuxtaposedContinuation() {
            value = .binary(left: value, operator: "+", right: parseExpression())
            giveback = nil
        }
        return (value, giveback)
    }

    private func startsJuxtaposedContinuation() -> Bool {
        switch peek {
        case .string, .variable: return true
        case .symbol("("): return true
        default: return false
        }
    }

    mutating private func readIdentifier() -> String {
        guard case let .identifier(name) = advance() else { return "<unknown>" }
        return name
    }

    mutating private func readMemberName() -> String {
        switch advance() {
        case let .identifier(name), let .string(name):
            return name
        default:
            return "<unknown>"
        }
    }

    private var peek: Token { tokens[min(index, tokens.count - 1)] }

    mutating private func advance() -> Token {
        defer { index = min(index + 1, tokens.count) }
        return peek
    }

    mutating private func consume(_ symbol: String) -> Bool {
        guard peek == .symbol(symbol) else { return false }
        index += 1
        return true
    }

    private static let precedence = [
        "=": 1, "+=": 1, "-=": 1, "*=": 1, "/=": 1,
        "||": 2, "&&": 3, "==": 4, "!=": 4, ">": 5, "<": 5,
        ">=": 5, "<=": 5, ">>": 5, "+": 6, "-": 6, "*": 7, "/": 7, "%": 7,
    ]

    /// `+=`/`-=`/`*=`/`/=` is sugar for `target = target OP value` — maps
    /// a compound-assignment symbol to the plain binary operator it
    /// expands around.
    private static let compoundAssignmentOperators = ["+=": "+", "-=": "-", "*=": "*", "/=": "/"]
}
