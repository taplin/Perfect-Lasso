import Foundation

struct TypeBodyParser {
    private let characters: [Character]
    private let typeName: String
    private let range: SourceRange
    private var index = 0
    private var dataMembers: [LassoDataMemberDefinition] = []
    private var methods: [LassoMethodDefinition] = []
    private(set) var diagnostics: [Diagnostic] = []
    /// Tag-open-form recognition counts folded up from every nested
    /// `ScriptBodyParser` this instance constructs for a method body
    /// (Phase 3 of tag-form consolidation).
    private(set) var openFormFires: [TagOpenFormFire: Int] = [:]

    init(source: String, typeName: String, range: SourceRange) {
        characters = Array(source)
        self.typeName = typeName
        self.range = range
    }

    mutating func parse() -> LassoTypeDefinition {
        while index < characters.count {
            skipTrivia()
            guard index < characters.count else { break }

            if readKeyword("data") {
                parseDataSection()
                continue
            }

            if let visibility = readVisibility() {
                parseMethod(visibility: visibility)
                continue
            }

            skipLineRemainder()
        }
        return LassoTypeDefinition(name: typeName, dataMembers: dataMembers, methods: methods)
    }

    private mutating func parseDataSection() {
        let declaration = readLineContinuingCommas()
        for item in splitTopLevelCommas(declaration) {
            guard let member = parseDataMember(item) else { continue }
            dataMembers.append(member)
        }
    }

    private func parseDataMember(_ source: String) -> LassoDataMemberDefinition? {
        var text = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.isEmpty == false else { return nil }

        var visibility: LassoMemberVisibility?
        for candidate in [LassoMemberVisibility.public, .protected, .private] {
            let prefix = candidate.rawValue
            if text.lowercased().hasPrefix(prefix + " ") {
                visibility = candidate
                text = String(text.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                break
            }
        }

        let (beforeDefault, defaultSource) = splitOnce(text, marker: "=")
        let (nameSource, typeSource) = splitOnce(beforeDefault, marker: "::")
        let name = nameSource.trimmingCharacters(in: .whitespacesAndNewlines)
        guard name.isEmpty == false else { return nil }

        let defaultValue: LassoExpression?
        if let defaultSource {
            var parser = ExpressionParser(defaultSource)
            defaultValue = parser.parseExpression()
        } else {
            defaultValue = nil
        }

        return LassoDataMemberDefinition(
            name: name,
            typeConstraint: typeSource?.trimmingCharacters(in: .whitespacesAndNewlines),
            defaultValue: defaultValue,
            visibility: visibility
        )
    }

    private mutating func parseMethod(visibility: LassoMemberVisibility) {
        skipHorizontalWhitespace()
        var name = readIdentifier()
        guard name.isEmpty == false else {
            diagnostics.append(Diagnostic(message: "Malformed type method: expected method name", range: range))
            skipLineRemainder()
            return
        }

        skipHorizontalWhitespace()
        // Ch. "Types" > "Custom Getters and Setters": `public firstName=
        // (value) => {...}` -- a member method NAME ending in `=`, called
        // via `#someone->firstName = "Bob"`. Real corpus (zeroloop/ds's
        // activerow.lasso): `public set=(val,col::tag) => ...`,
        // `public table=(p::tag) => {...}`, etc. `!matches("==")`/
        // `!matches("=>")` rule out equality and the association operator
        // -- an ordinary method signature always reaches its own `=>`
        // right after the parameter list (or return-type constraint),
        // never a bare `=` immediately after the name.
        if index < characters.count, characters[index] == "=", !matches("=="), !matches("=>") {
            index += 1
            name += "="
            skipHorizontalWhitespace()
        }
        var parameters: [LassoArgument] = []
        if index < characters.count, characters[index] == "(" {
            let body = readBalanced(open: "(", close: ")")
            parameters = parseCallArguments(name: name, body: body)
        }

        skipHorizontalWhitespace()
        var returnType: String?
        if matches("::") {
            index += 2
            skipHorizontalWhitespace()
            returnType = readIdentifier()
            skipHorizontalWhitespace()
        }

        guard matches("=>") else {
            diagnostics.append(Diagnostic(message: "Malformed type method '\(name)': expected '=>'", range: range))
            skipLineRemainder()
            return
        }
        index += 2
        skipHorizontalWhitespace()

        let bodyNodes: [LassoNode]
        if index < characters.count, characters[index] == "{" {
            let bodySource = readBalanced(open: "{", close: "}")
            bodyNodes = parseMethodBody(bodySource)
            skipLineRemainder()
        } else {
            // `readStatement()` already consumes through its own
            // trailing newline (real corpus: a bare-expression-bodied
            // method, e.g. `public firstName => .'firstName'`, is
            // usually followed immediately by another method on the
            // very next line) -- an unconditional `skipLineRemainder()`
            // here would silently swallow that ENTIRE next line/method,
            // never reaching `methods.append` for it at all. Found via
            // a real failing case: a getter/setter pair where the bare-
            // expression getter's own line-consumption ate the setter
            // right below it.
            let expressionSource = readStatement()
            bodyNodes = parseExpressionMethodBody(expressionSource)
        }

        methods.append(LassoMethodDefinition(
            name: name,
            parameters: parameters,
            returnType: returnType,
            visibility: visibility,
            body: bodyNodes
        ))
    }

    private mutating func parseMethodBody(_ source: String) -> [LassoNode] {
        var parser = ScriptBodyParser(source: source, range: range)
        let flat = parser.parse()
        diagnostics.append(contentsOf: parser.diagnostics)
        for (fire, count) in parser.openFormFires {
            openFormFires[fire, default: 0] += count
        }
        var builder = BlockBuilder(nodes: flat, diagnostics: [], openFormFires: [:])
        let result = builder.build()
        diagnostics.append(contentsOf: result.diagnostics)
        return result.nodes
    }

    private func parseExpressionMethodBody(_ source: String) -> [LassoNode] {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return [] }
        var parser = ExpressionParser("return(\(trimmed))")
        return [.code(parser.parseList(), .lasso9, .lassoscript, range)]
    }

    private func parseCallArguments(name: String, body: String) -> [LassoArgument] {
        // A fixed placeholder callee, not `name` itself -- a setter-style
        // name ending in `=` (`firstName=`) would otherwise reconstruct
        // as `firstName=(value)`, which `ExpressionParser` reads as an
        // ASSIGNMENT (`firstName = (value)`, `=` being a real, low-
        // precedence binary operator in this grammar) rather than a
        // call, silently producing zero parameters instead of the
        // intended one. Only `body`'s own content (the parameter list
        // text) is actually needed here; `name` plays no other role.
        var parser = ExpressionParser("__typeBodyParserParams__(\(body))")
        let expression = parser.parseExpression()
        guard case let .call(_, arguments) = expression else { return [] }
        return arguments
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

    private mutating func readLineContinuingCommas() -> String {
        var lines: [String] = []
        while index < characters.count {
            let line = readStatement()
            lines.append(line)
            if line.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix(",") {
                skipTrivia()
                continue
            }
            break
        }
        return lines.joined(separator: "\n")
    }

    private mutating func readStatement() -> String {
        let start = index
        var parenDepth = 0
        var quote: Character?

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
            } else if character == "(" {
                parenDepth += 1
            } else if character == ")" {
                parenDepth = max(parenDepth - 1, 0)
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

            // Real corpus (zeroloop/ds's ds.lasso): `// Don't store
            // connections...` -- a `//` comment containing an
            // apostrophe. Without this check, the quote-tracking below
            // treats that apostrophe as an OPENING string quote (comments
            // aren't string literals and don't need balancing, but this
            // scanner had no notion of comments at all), then scans for
            // the next apostrophe ANYWHERE in the remaining source to
            // "close" it -- silently swallowing everything in between,
            // including entire subsequent method definitions, into the
            // current method's own body text. An extremely common trigger
            // ("don't"/"it's"/"won't"/"can't" in ordinary English prose
            // comments), found via a real failing case where a type's
            // SECOND `store` overload vanished entirely, its own source
            // absorbed into the FIRST `store` method's body -- and then,
            // once inside there, misparsed as an ordinary unbound
            // `store(...)` call, surfacing as `unknownFunction("store")`.
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
        let end = index
        if index < characters.count, characters[index] == close {
            index += 1
        } else {
            diagnostics.append(Diagnostic(message: "Unterminated '\(open)' ... '\(close)'", range: range))
        }
        return String(characters[start..<end])
    }

    private mutating func readVisibility() -> LassoMemberVisibility? {
        let start = index
        let name = readIdentifier().lowercased()
        guard let visibility = LassoMemberVisibility(rawValue: name) else {
            index = start
            return nil
        }
        return visibility
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

    private mutating func readIdentifier() -> String {
        let start = index
        while index < characters.count,
              characters[index].isLetter || characters[index].isNumber || characters[index] == "_" {
            index += 1
        }
        return String(characters[start..<index])
    }

    private func splitTopLevelCommas(_ source: String) -> [String] {
        var parts: [String] = []
        var start = source.startIndex
        var parenDepth = 0
        var quote: Character?
        var index = source.startIndex

        while index < source.endIndex {
            let character = source[index]
            if let activeQuote = quote {
                if character == activeQuote { quote = nil }
            } else if character == "'" || character == "\"" || character == "`" {
                quote = character
            } else if character == "(" {
                parenDepth += 1
            } else if character == ")" {
                parenDepth = max(parenDepth - 1, 0)
            } else if character == ",", parenDepth == 0 {
                parts.append(String(source[start..<index]))
                start = source.index(after: index)
            }
            index = source.index(after: index)
        }
        parts.append(String(source[start..<source.endIndex]))
        return parts
    }

    private func splitOnce(_ source: String, marker: String) -> (String, String?) {
        guard let range = source.range(of: marker) else { return (source, nil) }
        return (String(source[..<range.lowerBound]), String(source[range.upperBound...]))
    }

    private func matches(_ text: String) -> Bool {
        let candidate = Array(text)
        guard index + candidate.count <= characters.count else { return false }
        return Array(characters[index..<(index + candidate.count)]) == candidate
    }
}
