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

        for op in ["->", "==", "!=", ">=", "<=", "&&", "||", "::", "=>", ">>"] where matches(op) {
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
                value.append(characters[index])
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
            let right = parseExpression(minimumPrecedence: precedence + (op == "=" ? 0 : 1))
            left = op == "=" ? .assignment(target: left, value: right) :
                .binary(left: left, operator: op, right: right)
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
            case "null", "void": expression = .null
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
            } else if consume("->") {
                let wrapped = consume("(")
                let name = readMemberName()
                let arguments: [LassoArgument]?
                if wrapped {
                    arguments = consume(":") ? parseArguments(closing: ")") : finishWrappedMember()
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

    mutating private func finishWrappedMember() -> [LassoArgument]? {
        if consume(")") { return [] }
        return parseArguments(closing: ")")
    }

    mutating private func parseArguments(closing: String?) -> [LassoArgument] {
        var arguments: [LassoArgument] = []
        while peek != .eof {
            if let closing, consume(closing) { break }
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
            arguments.append(LassoArgument(label: label, value: parseExpression()))
            if !consume(",") {
                if let closing { _ = consume(closing) }
                break
            }
        }
        return arguments
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
        "=": 1, "||": 2, "&&": 3, "==": 4, "!=": 4, ">": 5, "<": 5,
        ">=": 5, "<=": 5, ">>": 5, "+": 6, "-": 6, "*": 7, "/": 7, "%": 7,
    ]
}
