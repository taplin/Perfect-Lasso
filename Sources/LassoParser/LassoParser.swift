import Foundation

public struct LassoParser: Sendable {
    public init() {}

    public func parse(_ source: String) -> LassoDocument {
        var scanner = TemplateScanner(source)
        let scanned = scanner.scan()
        var builder = BlockBuilder(nodes: scanned.nodes, diagnostics: scanned.diagnostics)
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

    init(_ source: String) {
        characters = Array(source)
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
            } else if squareBracketsEnabled, characters[index] == "[", startsBracketComment(at: index) {
                emitText(through: index)
                scanBracketComment()
            } else if squareBracketsEnabled, characters[index] == "[" {
                emitText(through: index)
                scanSquare()
            } else {
                index += 1
            }
        }
        emitText(through: characters.count)
        return LassoDocument(nodes: nodes, diagnostics: diagnostics)
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
                if character == activeQuote { quote = nil }
            } else if character == "'" || character == "\"" {
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
        if body.hasPrefix("/") {
            let name = body.dropFirst().trimmingCharacters(in: .whitespacesAndNewlines)
            nodes.append(.tag(name: name, arguments: [], closing: true, dialect: .lasso8, range: range))
            return
        }

        if delimiter == .square, let defineTag = Self.parseDefineTag(body: body, dialect: dialect, range: range) {
            nodes.append(defineTag)
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
            return
        }

        var parser = ExpressionParser(body)
        let expressions = parser.parseList()
        if delimiter == .square, let first = expressions.first {
            if case let .call(callee, arguments) = first,
               case let .identifier(name) = callee,
               Self.blockTagNames.contains(name.lowercased()) {
                nodes.append(.tag(name: name, arguments: arguments, closing: false, dialect: dialect, range: range))
            } else if case let .identifier(name) = first,
                      Self.blockTagNames.contains(name.lowercased()) {
                nodes.append(.tag(name: name, arguments: [], closing: false, dialect: dialect, range: range))
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

    private static let blockTagNames: Set<String> = [
        "if", "else", "inline", "records", "rows", "loop", "iterate", "while", "define", "protect",
    ]
}
