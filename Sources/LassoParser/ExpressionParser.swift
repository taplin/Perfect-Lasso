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
        // Ch. "Language" > "Literals" > "String Literals": "Lasso
        // supports two kinds of string literals: quoted and ticked...
        // A ticked string is a series of zero or more characters
        // surrounded by a pair of backticks. Within a ticked string,
        // the backslash character holds no special meaning." A THIRD,
        // entirely separate string-literal delimiter from the single/
        // double quotes just above — not a quote-STYLE variant of them
        // (an earlier investigation, during Captures Stage 5, initially
        // read lassoguide.com's own `string->unescape()` phrase "the
        // same escape process used by Lasso for non-ticked string
        // literals" as implying single- vs double-quoted strings had
        // DIFFERENT escape rules from each other; re-checked directly
        // against this page and found that's wrong — "non-ticked" means
        // "quoted" (single OR double, identical rules, confirmed by this
        // same page's own worked examples using both interchangeably).
        // Real, useful, and entirely unimplemented before this fix:
        // "particularly useful when using regular expressions which
        // often require many backslashes" (the doc's own stated
        // motivation) — zero occurrences in either real corpus sampled
        // by this project (which skews Lasso 8.5-era, predating this
        // Lasso 9 syntax), but implemented anyway per real-Lasso-9
        // completeness (see this project's own
        // corpus-evidence-not-sole-bar convention).
        if character == "`" { return .string(readTickedString()) }
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
                index = appendEscape(into: &value, startingAt: index)
            } else {
                value.append(character)
            }
        }
        return value
    }

    /// Ch. "Literals" > "String Literals" > "Quoted Strings" >
    /// "Supported String Escape Sequences" — the full documented table,
    /// superseding an earlier cut that only handled `\n`/`\t`/`\r` and
    /// silently dropped the backslash for everything else (found live:
    /// real corpus HTML-building string literals like
    /// `'...\n|<br>|...'` need `\n` as an actual newline).
    ///
    /// An UNRECOGNIZED escape (not in the documented table at all) is
    /// itself not documented one way or the other — this page presents a
    /// closed, exhaustive list with no "anything else" clause. Passed
    /// through literally here (BOTH the backslash and the following
    /// character kept, e.g. `\d` stays `\d`), the safer, less-destructive
    /// reading versus the previous "drop the backslash" behavior — real
    /// corpus regex patterns written as quoted strings (not ticked ones,
    /// which didn't exist in this parser until this same fix) rely on
    /// `\d`/`\w`/`\s`-style shorthand surviving intact for a downstream
    /// regex engine, and this codebase's other lookup-miss conventions
    /// already favor non-corrupting defaults over silent data loss.
    ///
    /// `\:NAME:` (Unicode character by name) is the one documented form
    /// NOT implemented — it would need a full Unicode character-name
    /// database this Swift/Foundation-based project has no bound access
    /// to (no such database is used anywhere else in this codebase
    /// either). Disclosed, not faked; zero corpus evidence for it.
    mutating private func appendEscape(into value: inout String, startingAt start: Int) -> Int {
        var index = start
        let character = characters[index]
        switch character {
        case "a": value.append("\u{07}"); index += 1
        case "b": value.append("\u{08}"); index += 1
        case "e": value.append("\u{1B}"); index += 1
        case "f": value.append("\u{0C}"); index += 1
        case "n": value.append("\n"); index += 1
        case "r": value.append("\r"); index += 1
        case "t": value.append("\t"); index += 1
        case "v": value.append("\u{0B}"); index += 1
        case "\"", "'", "?", "\\":
            value.append(character)
            index += 1
        case "x":
            index = appendHexEscape(into: &value, prefix: "x", startingAt: index + 1, digitCount: 1...2)
        case "u":
            index = appendHexEscape(into: &value, prefix: "u", startingAt: index + 1, digitCount: 4...4)
        case "U":
            index = appendHexEscape(into: &value, prefix: "U", startingAt: index + 1, digitCount: 8...8)
        case "\r", "\n":
            // "A backslash followed by an end-of-line... will cause that
            // end-of-line and all following literal whitespace to be
            // removed from the resulting string" — a line-continuation
            // escape, not a character-producing one. `\r\n` counts as
            // ONE end-of-line (the doc's own wording: "a literal line
            // feed or carriage return or carriage return/line feed
            // pair").
            if character == "\r", index + 1 < characters.count, characters[index + 1] == "\n" {
                index += 1
            }
            index += 1
            while index < characters.count, characters[index].isWhitespace {
                index += 1
            }
        default:
            if let digit = character.wholeNumberValue, digit <= 7 {
                index = appendOctalEscape(into: &value, startingAt: index)
            } else {
                value.append("\\")
                value.append(character)
                index += 1
            }
        }
        return index
    }

    /// `\x dd` (1-2 hex digits), `\u dddd` (exactly 4), `\U dddddddd`
    /// (exactly 8) — a short digit run that doesn't meet the required
    /// count (malformed) is passed through literally (prefix letter +
    /// whatever digits WERE found) rather than silently dropped, same
    /// reasoning as `appendEscape`'s own unrecognized-escape fallback.
    private func appendHexEscape(
        into value: inout String, prefix: Character, startingAt start: Int, digitCount: ClosedRange<Int>
    ) -> Int {
        var index = start
        var digits = ""
        while index < characters.count, digits.count < digitCount.upperBound, characters[index].isHexDigit {
            digits.append(characters[index])
            index += 1
        }
        if digitCount.contains(digits.count), let codepoint = UInt32(digits, radix: 16),
           let scalar = Unicode.Scalar(codepoint) {
            value.append(Character(scalar))
        } else {
            value.append("\\")
            value.append(prefix)
            value.append(digits)
        }
        return index
    }

    /// `\ ddd` — "Unicode character 1–3 octal digits". Same malformed-
    /// fallback reasoning as `appendHexEscape`.
    private func appendOctalEscape(into value: inout String, startingAt start: Int) -> Int {
        var index = start
        var digits = ""
        while index < characters.count, digits.count < 3, let digit = characters[index].wholeNumberValue, digit <= 7 {
            digits.append(characters[index])
            index += 1
        }
        if let codepoint = UInt32(digits, radix: 8), let scalar = Unicode.Scalar(codepoint) {
            value.append(Character(scalar))
        } else {
            value.append("\\")
            value.append(contentsOf: digits)
        }
        return index
    }

    /// Ch. "Literals" > "String Literals" > "Ticked Strings": "Within a
    /// ticked string, the backslash character holds no special
    /// meaning... a literal backtick character cannot appear within a
    /// ticked string" — no escape mechanism at all, so there's no way to
    /// include one; matches the doc's own stated caveat rather than
    /// inventing an undocumented escape for it.
    mutating private func readTickedString() -> String {
        index += 1
        var value = ""
        while index < characters.count {
            let character = characters[index]
            index += 1
            if character == "`" { break }
            value.append(character)
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
                // Ch. "Literals" > "Ticked Strings": no escape mechanism
                // inside a ticked string — see the identical fix's own
                // doc comment in ScriptBodyParser.swift for the full
                // rationale (found by architect + code-reviewer review
                // of the ticked-string investigation).
                if character == "\\", activeQuote != "`" {
                    index = min(index + 1, characters.count)
                } else if character == activeQuote {
                    quote = nil
                }
                continue
            }
            if character == "'" || character == "\"" || character == "`" {
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
            let whenTrue = parseTernaryAction()
            if consume("|") {
                let whenFalse = parseTernaryAction()
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

    /// Parses a ternary's action clause (the `whenTrue`/`whenFalse` after
    /// `?`/`|`), applying the same bare-`return`/`yield`-to-real-call
    /// rewrite `ScriptBodyParser.normalizeReturn` applies to a WHOLE
    /// statement — without this, `x == 1 ? return true` falls through to
    /// the generic juxtaposition/string-concatenation sugar (bare
    /// identifier `return`, evaluating to an unrelated undefined
    /// variable, concatenated with `true`) instead of ever calling the
    /// real `register("return")`/`register("yield")` native function,
    /// because `normalizeReturn`'s own `hasPrefix` check only ever sees
    /// the ternary's FULL statement text (`x == 1 ? return true`), which
    /// doesn't start with "return "/"yield ". A bare keyword immediately
    /// followed by `(` (`return(true)`) is left alone here — that shape
    /// already parses correctly as an ordinary call via
    /// `parsePostfixTrackingGiveback`'s own `(` handling.
    ///
    /// A *valueless* bare `return`/`yield` (`$done ? return`, or
    /// `$done ? return | 5`) must NOT fall into the value-parsing branch
    /// below — `register("return")`/`register("yield")` (Runtime.swift)
    /// already default a missing argument to `.void`, matching real
    /// Lasso's zero-arg `return`/`yield`. Found by code review: blindly
    /// calling `parseExpression()` for "the value" when there isn't one
    /// either throws (next token is `.eof`, consumed as `.unknown("")`,
    /// which `Evaluator` rejects) or, worse, silently eats the ternary's
    /// own `|` separator (single `|` isn't a registered binary operator,
    /// so it falls to the prefix parser's symbol catch-all as
    /// `.unknown("|")`), corrupting the whenFalse branch. `canStartValue`
    /// below whitelists exactly the tokens `parsePrefixTrackingGiveback`
    /// can actually start a real expression from — anything else (`|`,
    /// `)`, `,`, `:`, EOF, ...) means no value follows, and this emits a
    /// zero-argument call instead of guessing one into existence.
    mutating private func parseTernaryAction() -> LassoExpression {
        if case let .identifier(name) = peek,
           ["return", "yield"].contains(name.lowercased()) {
            let next = tokens[min(index + 1, tokens.count - 1)]
            if next != .symbol("(") {
                index += 1
                guard Self.canStartValue(next) else {
                    return .call(callee: .identifier(name), arguments: [])
                }
                let value = parseExpression()
                return .call(callee: .identifier(name), arguments: [LassoArgument(value: value)])
            }
        }
        return parseExpression()
    }

    /// Whether `token` can legitimately begin a fresh expression — i.e.
    /// is one of the cases `parsePrefixTrackingGiveback` actually has a
    /// real production for, as opposed to falling into its `.symbol`/
    /// `.eof` catch-alls (`.unknown(...)`). Used by `parseTernaryAction`
    /// to tell "a value follows" from "nothing follows" (see its own
    /// doc comment).
    private static func canStartValue(_ token: Token) -> Bool {
        switch token {
        case .string, .integer, .decimal, .variable, .tagReference, .identifier, .named, .captureBody:
            return true
        case let .symbol(value):
            return ["(", "!", "-", "+", "."].contains(value)
        case .eof:
            return false
        }
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
            case "with":
                // Ch. "Query Expressions": `with NAME in SOURCE (select
                // EXPR | do (EXPR|CAPTURE))` — see
                // `tryParseQueryExpression`'s own doc comment for the
                // full speculative-parse/backtrack design and how this
                // coexists with the pre-existing STATEMENT-level `with
                // NAME in EXPR do { body }` block tag.
                if let queryExpression = tryParseQueryExpression() {
                    expression = queryExpression
                    // Already a self-contained, unambiguous unit, same
                    // reasoning as the capture-literal/parenthesized-
                    // group cases below.
                    eligibleForGiveback = false
                } else {
                    expression = .identifier(name)
                }
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

    /// `with NAME in SOURCE (select EXPR | do (EXPR|CAPTURE))` — Ch.
    /// "Query Expressions". Reached only from expression position (the
    /// leading "with" token is already consumed by the caller); fully
    /// speculative with backtrack-to-`nil` on ANY mismatch, restoring
    /// `index` to right after "with" — so a bare `with` used as an
    /// ordinary identifier (real corpus regression guard:
    /// `malformedWithFallsBackToOrdinaryCodeWithoutSwallowingNextStatement`,
    /// e.g. `with = 5`) is completely unaffected; the caller falls back
    /// to `.identifier("with")` exactly as before this addition existed.
    ///
    /// Deliberately does NOT recognize `do { block }` (a parsed
    /// STATEMENT body) — only a bare EXPRESSION or a CAPTURE LITERAL
    /// VALUE for `do`'s payload, matching the real docs' own wording
    /// ("a `do` clause consists of the word `do` followed by either a
    /// single expression or a capture"). The pre-existing, separate
    /// STATEMENT-level `with NAME in EXPR do { body }` block tag
    /// (`ScriptBodyParser.parseWithOpening`) already owns that exact
    /// shape and is recognized BEFORE this expression parser ever runs
    /// on a bare top-level `with` statement — this function only ever
    /// sees `with` when it's already nested inside a LARGER expression
    /// (an assignment's right-hand side, a call argument, etc.), a
    /// structural position the statement-level tag never reaches. A
    /// `{...}`/`{^...^}` capture-literal `do` payload here is parsed as
    /// an ordinary `.captureLiteral` expression via `parseExpression`
    /// (the lexer already tokenizes a leading `{` as `.captureBody`
    /// regardless of surrounding context), so no special-casing is
    /// needed to distinguish the two `do` payload shapes at parse time.
    mutating private func tryParseQueryExpression() -> LassoExpression? {
        let start = index
        guard case let .identifier(variable) = peek else { return nil }
        index += 1
        guard case let .identifier(inKeyword) = peek, inKeyword.caseInsensitiveCompare("in") == .orderedSame else {
            index = start
            return nil
        }
        index += 1
        let source = parseExpression()
        // Ch. "Query Expressions", "Operations": zero or more `where`/
        // `let`/`skip`/`take`/`order by` clauses (Stage 8.2 added the
        // first four, Stage 8.3 adds `order by`), in ANY order, applied
        // IN THE ORDER WRITTEN — `tryParseQueryOperation` returns `nil`
        // (with no index mutation) as soon as the next token doesn't
        // match a known operation keyword, which is exactly when the
        // action is expected next. `group` (Stage 8.4's own real,
        // documented operation) isn't recognized here yet — a query
        // expression using it falls all the way through to this
        // function's own full backtrack below, same as any other
        // unrecognized shape, rather than a targeted "not yet
        // implemented" diagnostic; disclosed, not a silent wrong answer
        // (the resulting bareword-`with` reinterpretation fails loudly
        // downstream, matching this codebase's established "unsupported
        // input surfaces as a real error, never a silent wrong result"
        // convention elsewhere).
        var operations: [QueryOperation] = []
        while let operation = tryParseQueryOperation() {
            operations.append(operation)
        }
        if case let .identifier(actionKeyword) = peek {
            switch actionKeyword.lowercased() {
            case "select":
                index += 1
                let transform = parseExpression()
                return .queryExpression(variable: variable, source: source, operations: operations, action: .select(transform))
            case "do":
                index += 1
                let payload = parseExpression()
                return .queryExpression(variable: variable, source: source, operations: operations, action: .perform(payload))
            case "sum":
                index += 1
                return .queryExpression(variable: variable, source: source, operations: operations, action: .sum(parseExpression()))
            case "average":
                index += 1
                return .queryExpression(variable: variable, source: source, operations: operations, action: .average(parseExpression()))
            case "min":
                index += 1
                return .queryExpression(variable: variable, source: source, operations: operations, action: .min(parseExpression()))
            case "max":
                index += 1
                return .queryExpression(variable: variable, source: source, operations: operations, action: .max(parseExpression()))
            default:
                break
            }
        }
        index = start
        return nil
    }

    /// One `where`/`let`/`skip`/`take`/`order by` operation — `nil`,
    /// with NO index mutation, as soon as the next token doesn't match
    /// a known operation keyword (the caller's loop then expects the
    /// action next). `let` additionally requires `NAME =` after the
    /// keyword itself (Ch. "Query Expressions": "the word `let` followed
    /// by a new variable name, the assignment operator (`=`), and then
    /// an expression") — a `let` keyword not followed by that exact
    /// shape is treated as a hard parse failure for the WHOLE query
    /// expression (falls through to `tryParseQueryExpression`'s own
    /// final backtrack), not silently reinterpreted as some other
    /// construct, since `let` alone is otherwise meaningless here. Same
    /// discipline for `order` not followed by `by`.
    mutating private func tryParseQueryOperation() -> QueryOperation? {
        guard case let .identifier(keyword) = peek else { return nil }
        switch keyword.lowercased() {
        case "where":
            index += 1
            return .filter(parseExpression())
        case "skip":
            index += 1
            return .skip(parseExpression())
        case "take":
            index += 1
            return .take(parseExpression())
        case "let":
            let start = index
            index += 1
            guard case let .identifier(name) = peek else {
                index = start
                return nil
            }
            index += 1
            guard consume("=") else {
                index = start
                return nil
            }
            return .let(name: name, value: parseExpression())
        case "order":
            let start = index
            index += 1
            guard case let .identifier(byKeyword) = peek, byKeyword.caseInsensitiveCompare("by") == .orderedSame else {
                index = start
                return nil
            }
            index += 1
            // Ch. "Query Expressions", "Order By": "further ordering
            // criteria can be specified by following the initial order
            // by expression with a comma, and then the next ordering
            // expression and optional direction indicator" — one or
            // more comma-separated `EXPR [ascending|descending]` keys.
            var keys: [QueryOrderKey] = []
            repeat {
                let keyExpression = parseExpression()
                var descending = false
                if case let .identifier(direction) = peek {
                    if direction.caseInsensitiveCompare("descending") == .orderedSame {
                        descending = true
                        index += 1
                    } else if direction.caseInsensitiveCompare("ascending") == .orderedSame {
                        index += 1
                    }
                }
                keys.append(QueryOrderKey(expression: keyExpression, descending: descending))
            } while consume(",")
            return .orderBy(keys)
        default:
            return nil
        }
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
