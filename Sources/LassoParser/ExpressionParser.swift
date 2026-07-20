private enum Token: Equatable {
    case identifier(String)
    case variable(String, VariableScope)
    case string(String)
    case integer(Int)
    case decimal(Double)
    case named(String)
    case symbol(String)
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
        if character == "$" || character == "#" {
            index += 1
            return .variable(readIdentifier(), character == "$" ? .global : .local)
        }
        if character == "-", index + 1 < characters.count, characters[index + 1].isLetter {
            index += 1
            return .named(readIdentifier())
        }
        if character.isLetter || character == "_" { return .identifier(readIdentifier()) }

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

    /// True while parsing the value of a bare colon-call argument (`closing
    /// == nil` in `parseArguments`) — real Lasso's colon syntax has no
    /// closing delimiter of its own, so per the Lasso 8.5 Language Guide's
    /// "Colon Syntax" section, an unparenthesized nested/trailing construct
    /// binds to the *outermost* call, not to the argument being parsed.
    /// Concretely: `$arr->get:2->first` must parse as `($arr->get:2)->first`
    /// (`->first` targets the call's result), not `$arr->get:(2->first)`
    /// (which crashes — `2` has no `first` member). Suppressing `->` here
    /// stops `parsePostfix` from greedily absorbing that trailing member
    /// access into the argument value; it's lifted again the moment we
    /// enter any parenthesized (unambiguously bounded) sub-expression. Real
    /// corpus (`->get:1`-style calls, 70+ sites) never puts a `->` inside a
    /// bare colon-call's own argument, so this never suppresses anything
    /// real code relies on.
    private var suppressArrowPostfix = false

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
        var left = parsePrefix()
        while consume("::") {
            left = .binary(left: left, operator: "::", right: parseTypeConstraint())
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
        }
        return left
    }

    mutating private func parsePrefix() -> LassoExpression {
        let expression: LassoExpression
        switch advance() {
        case let .string(value): expression = .string(value)
        case let .integer(value): expression = .integer(value)
        case let .decimal(value): expression = .decimal(value)
        case let .variable(name, scope): expression = .variable(name, scope)
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
            let previousSuppression = suppressArrowPostfix
            suppressArrowPostfix = false
            expression = parseExpression()
            suppressArrowPostfix = previousSuppression
            _ = consume(")")
        case let .named(name): expression = .unknown("-\(name)")
        case let .symbol(value): expression = .unknown(value)
        case .eof: return .unknown("")
        }
        return parsePostfix(expression)
    }

    mutating private func parsePostfix(_ initial: LassoExpression) -> LassoExpression {
        var expression = initial
        while true {
            if consume("(") {
                expression = .call(callee: expression, arguments: parseArguments(closing: ")"))
            } else if consume(":") {
                expression = .call(callee: expression, arguments: parseArguments(closing: nil))
            } else if !suppressArrowPostfix, consume("->") {
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
            } else {
                return expression
            }
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
        let previousSuppression = suppressArrowPostfix
        suppressArrowPostfix = (closing == nil)
        defer { suppressArrowPostfix = previousSuppression }
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
            arguments.append(LassoArgument(label: label, value: parseJuxtaposedValue()))
            if !consume(",") {
                if let closing { _ = consume(closing) }
                break
            }
        }
        return arguments
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
        var value = parseExpression()
        while startsJuxtaposedContinuation() {
            value = .binary(left: value, operator: "+", right: parseExpression())
        }
        return value
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
