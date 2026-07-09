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
            if parseDefineOpening() { continue }
            if parseBlockOpening() { continue }
            if parseIgnoredBrace() { continue }

            let statement = readStatement()
            emitStatement(statement)
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
        if consumeArrowBlockStartIfPresent() {
            openBraceBlockStack.append(name)
        }
        skipLineRemainder()
        nodes.append(.tag(name: name, arguments: arguments, closing: false, dialect: .lasso9, range: range))
        return true
    }

    /// Handles `define name(params) => { body }`, compiling a reusable
    /// custom tag directly (bypassing the flat open/close-tag pairing the
    /// rest of this parser uses, since the whole nested body is already in
    /// hand once the balanced `{ }` is extracted). `define Foo => type {
    /// ... }` object/type definitions are recognized and skipped past
    /// (consumed, not registered) — full object-model support is out of
    /// scope for now.
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
        skipHorizontalWhitespace()

        if readKeyword("type") {
            skipHorizontalWhitespace()
            if index < characters.count, characters[index] == "{" {
                _ = readBalanced(open: "{", close: "}")
            }
            skipLineRemainder()
            diagnostics.append(Diagnostic(
                message: "Object/type definitions ('=> type { ... }') are not yet supported",
                range: range
            ))
            return true
        }

        guard index < characters.count, characters[index] == "{" else {
            diagnostics.append(Diagnostic(message: "Malformed 'define \(name) => ': expected '{'", range: range))
            index = start
            return false
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

    private mutating func emitStatement(_ statement: String) {
        let trimmed = statement.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var parser = ExpressionParser(normalizeReturn(trimmed))
        let expressions = parser.parseList()
        if !expressions.isEmpty {
            nodes.append(.code(expressions, .lasso9, delimiter, range))
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
        } else {
            diagnostics.append(Diagnostic(message: "Unterminated '\(open)' ... '\(close)'", range: range))
        }
        return String(characters[start..<end])
    }

    /// Returns `true` if a brace body start (`"=> {"` or a bare `"{"`) was
    /// consumed, so the caller knows to track this block for later
    /// implicit closing by a bare `}` (see `openBraceBlockStack`).
    private mutating func consumeArrowBlockStartIfPresent() -> Bool {
        skipHorizontalWhitespace()
        if matches("=>") {
            index += 2
            skipHorizontalWhitespace()
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

    private static let blockNames: Set<String> = [
        "if", "inline", "records", "rows", "loop", "iterate", "while", "protect",
    ]
}
