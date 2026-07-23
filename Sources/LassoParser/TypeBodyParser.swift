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
            parameters = parseSignatureParameters(name: name, body: body)
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
        //
        // ORDINARY call-argument lists only -- deliberately NOT used for
        // method SIGNATURES, which need `parseSignatureParameters`
        // below instead. A real, once-shipped bug: sharing this one
        // function for both broke `loop(-count=3) => {...}` in
        // ScriptBodyParser (a real CALL, whose `-count` label must
        // survive intact) the moment dash-stripping was added here
        // directly -- confirmed via a full-suite regression
        // (`bareReturnAndYieldWorkAsATernaryActionClause` et al.) before
        // being split back out.
        var parser = ExpressionParser("__typeBodyParserParams__(\(body))")
        let expression = parser.parseExpression()
        guard case let .call(_, arguments) = expression else { return [] }
        return arguments
    }

    /// SIGNATURE-only sibling of `parseCallArguments` just above -- used
    /// exclusively for a method's own parameter-list declaration
    /// (`parseMethod`), never for an ordinary call's arguments. See
    /// `stripKeywordParameterDashes`'s own doc comment for why keyword
    /// (`-name[::type][=default]`) SIGNATURE parameters need this
    /// separate handling.
    private func parseSignatureParameters(name: String, body: String) -> [LassoArgument] {
        var parser = ExpressionParser("__typeBodyParserParams__(\(stripKeywordParameterDashes(body)))")
        let expression = parser.parseExpression()
        guard case let .call(_, arguments) = expression else { return [] }
        return arguments
    }

    /// Ch. "Methods" > "Keyword Parameters": a SIGNATURE parameter may be
    /// declared `-name[::type][=default]` (e.g. `-find::string`,
    /// `-ignoreCase::boolean=false`) -- the leading `-` marks it as
    /// keyword-only (must be called via `-name=value`), but carries no
    /// meaning for this codebase's simpler binding model once bound (see
    /// `Evaluator.bindParameters`'s own label-then-positional fallback,
    /// which already treats every parameter uniformly regardless of how
    /// it was declared). Left alone, this reconstruction's throwaway
    /// `ExpressionParser` sub-parse tokenizes `-name` as a `.named`
    /// token -- the SAME token a real CALL SITE's `-name=value` produces
    /// -- and `parseArguments`'s `.named` handling expects the value to
    /// follow `=` DIRECTLY; a signature's `::type` sitting in between
    /// desyncs it badly enough that the whole reconstructed parse stops
    /// matching `.call(...)`, silently discarding EVERY parameter (found
    /// live: zeroloop/ds's `ds.lasso`, `oncreate`'s 14-parameter "core
    /// inline params" overload -- confirmed via a minimal repro that
    /// even a SINGLE `-datasource::string='mysqlds'` parameter alone
    /// reproduces it). Fixed here rather than in the shared
    /// `ExpressionParser.parseArguments`/`.named` handling itself, which
    /// stays completely unchanged and correct for its real job (real
    /// call-site `-name=value` arguments, used constantly throughout
    /// this codebase) -- this strips the leading `-` from each
    /// TOP-LEVEL parameter's name BEFORE reconstruction, so
    /// `-name::type=default` becomes plain `name::type=default`, which
    /// already parses correctly via the ordinary (non-`.named`)
    /// `::`/`=` expression grammar, exactly like a non-keyword parameter
    /// with the same shape.
    ///
    /// Comment/quote/nesting-aware (learned from this same session's
    /// `readBalanced` comment-desync bug) so a `-` inside a string
    /// literal default, a comment between parameters, or a negative-
    /// number default nested inside a parenthesized/bracketed
    /// sub-expression is never mistaken for a new parameter's own
    /// leading dash -- only a `-` immediately at a top-level parameter
    /// boundary (the very start of `body`, or right after a top-level
    /// `,`) followed by a letter qualifies.
    private func stripKeywordParameterDashes(_ body: String) -> String {
        let characters = Array(body)
        var result = ""
        result.reserveCapacity(characters.count)
        var index = 0
        var quote: Character?
        var depth = 0
        var atParameterStart = true

        while index < characters.count {
            let character = characters[index]

            if let activeQuote = quote {
                result.append(character)
                if character == activeQuote { quote = nil }
                index += 1
                continue
            }
            if character == "'" || character == "\"" || character == "`" {
                quote = character
                result.append(character)
                index += 1
                atParameterStart = false
                continue
            }
            if character == "/", index + 1 < characters.count, characters[index + 1] == "/" {
                while index < characters.count, characters[index] != "\n" {
                    result.append(characters[index])
                    index += 1
                }
                continue
            }
            if character == "/", index + 1 < characters.count, characters[index + 1] == "*" {
                result.append(characters[index])
                result.append(characters[index + 1])
                index += 2
                while index + 1 < characters.count, !(characters[index] == "*" && characters[index + 1] == "/") {
                    result.append(characters[index])
                    index += 1
                }
                if index + 1 < characters.count {
                    result.append(characters[index])
                    result.append(characters[index + 1])
                    index += 2
                } else {
                    index = characters.count
                }
                continue
            }
            if character == "(" || character == "[" || character == "{" {
                depth += 1
                result.append(character)
                index += 1
                atParameterStart = false
                continue
            }
            if character == ")" || character == "]" || character == "}" {
                depth = max(depth - 1, 0)
                result.append(character)
                index += 1
                atParameterStart = false
                continue
            }
            if character == ",", depth == 0 {
                result.append(character)
                index += 1
                atParameterStart = true
                continue
            }
            if character.isWhitespace {
                result.append(character)
                index += 1
                continue
            }
            if atParameterStart, depth == 0, character == "-",
               index + 1 < characters.count, characters[index + 1].isLetter {
                index += 1
                atParameterStart = false
                continue
            }
            result.append(character)
            index += 1
            atParameterStart = false
        }
        return result
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
            // A trailing `//...` comment on the SAME line as a field
            // (real corpus: zeroloop/ds's `ds_row` type -- `private
            // ds::ds,\t\t\t\t\t//\tReference to ds`) must be stripped
            // BEFORE checking for a trailing comma, or the comment's own
            // text becomes the line's effective suffix and the comma
            // right before it is invisible to `hasSuffix(",")` -- same
            // silent-truncation failure mode as the blank/comment-only
            // LINE case just below, just triggered by a comment sharing
            // a line with real content instead of occupying its own.
            let rawLine = readStatement()
            let line = Self.strippingTrailingLineComment(from: rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            // A blank or comment-only line between comma-continued
            // fields doesn't itself end the declaration -- real corpus
            // (zeroloop/ds's `ds` type) has a blank line + a
            // `// Legacy: support action_params` comment sitting
            // between `results = staticarray,` and the next field.
            // Previously any such line (trivially not ending in a
            // comma) stopped the scan right there, silently dropping
            // every field after it from the type entirely -- not just
            // "losing a default value" (the narrower, already-known gap
            // `DsInfo.swift`'s own doc comment worked around by using
            // one field per line) but discarding the field
            // declarations themselves, which then got mis-parsed by the
            // OUTER `parse()` loop as malformed method definitions
            // instead. Must NOT be appended to `lines` -- the comment
            // text has no comma of its own to split on, so it would
            // otherwise glue onto whichever adjacent field's
            // declaration text follows and corrupt `parseDataMember`'s
            // visibility-prefix detection.
            if trimmed.isEmpty || trimmed.hasPrefix("//") {
                skipTrivia()
                continue
            }
            lines.append(line)
            if trimmed.hasSuffix(",") {
                skipTrivia()
                continue
            }
            break
        }
        return lines.joined(separator: "\n")
    }

    /// Truncates `line` at the first `//` that isn't inside a quoted
    /// string (`'`/`"`/`` ` ``, matching `readStatement`'s own quote
    /// tracking) -- a plain substring search would misfire on a `//`
    /// that happens to appear inside a string literal value, though no
    /// real corpus sighting of that shape exists yet for this
    /// specific call site.
    private static func strippingTrailingLineComment(from line: String) -> String {
        let chars = Array(line)
        var quote: Character?
        var index = 0
        while index < chars.count {
            let character = chars[index]
            if let activeQuote = quote {
                if character == "\\", activeQuote != "`" {
                    index += 1
                } else if character == activeQuote {
                    quote = nil
                }
            } else if character == "'" || character == "\"" || character == "`" {
                quote = character
            } else if character == "/", index + 1 < chars.count, chars[index + 1] == "/" {
                return String(chars[0..<index])
            }
            index += 1
        }
        return line
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
