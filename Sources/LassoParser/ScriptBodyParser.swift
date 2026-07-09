import Foundation

struct ScriptBodyParser {
    private let characters: [Character]
    private let range: SourceRange
    private var index = 0
    private var nodes: [LassoNode] = []

    init(source: String, range: SourceRange) {
        characters = Array(source)
        self.range = range
    }

    mutating func parse() -> [LassoNode] {
        while index < characters.count {
            skipTrivia()
            guard index < characters.count else { break }

            if parseClosingTag() { continue }
            if parseElseTag() { continue }
            if parseBlockOpening() { continue }
            if parseIgnoredBrace() { continue }

            let statement = readStatement()
            emitStatement(statement)
        }
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
        consumeArrowBlockStartIfPresent()
        skipLineRemainder()
        if characters.indices.contains(start) {
            nodes.append(.tag(name: "else", arguments: arguments, closing: false, dialect: .lasso9, range: range))
        }
        return true
    }

    private mutating func parseBlockOpening() -> Bool {
        let start = index
        let name = readIdentifier()
        guard !name.isEmpty else { return false }
        let normalized = name.lowercased()
        guard Self.blockNames.contains(normalized) else {
            index = start
            return false
        }

        skipHorizontalWhitespace()
        guard index < characters.count, characters[index] == "(" else {
            index = start
            return false
        }

        let body = readBalanced(open: "(", close: ")")
        let arguments = parseCallArguments(name: name, body: body)
        consumeArrowBlockStartIfPresent()
        skipLineRemainder()
        nodes.append(.tag(name: name, arguments: arguments, closing: false, dialect: .lasso9, range: range))
        return true
    }

    private mutating func parseIgnoredBrace() -> Bool {
        guard characters[index] == "}" else { return false }
        index += 1
        skipLineRemainder()
        return true
    }

    private mutating func emitStatement(_ statement: String) {
        let trimmed = statement.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var parser = ExpressionParser(normalizeReturn(trimmed))
        let expressions = parser.parseList()
        if !expressions.isEmpty {
            nodes.append(.code(expressions, .lasso9, .lassoscript, range))
        }
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
                break
            }
            index += 1
        }

        let statement = String(characters[start..<index])
        if index < characters.count, characters[index] == "\n" {
            index += 1
        }
        return statement
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
        }
        return String(characters[start..<end])
    }

    private mutating func consumeArrowBlockStartIfPresent() {
        skipHorizontalWhitespace()
        if matches("=>") {
            index += 2
            skipHorizontalWhitespace()
        }
        if index < characters.count, characters[index] == "{" {
            index += 1
        }
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

    private static let blockNames: Set<String> = [
        "if", "inline", "records", "rows", "loop", "iterate", "while", "protect",
    ]
}
