struct BlockBuilder {
    let nodes: [LassoNode]
    var diagnostics: [Diagnostic]
    var index = 0

    mutating func build() -> LassoDocument {
        let result = buildSequence(until: nil)
        return LassoDocument(nodes: result.nodes, diagnostics: diagnostics)
    }

    private mutating func buildSequence(until expectedClose: String?) -> SequenceResult {
        var result: [LassoNode] = []
        var alternate: [LassoNode]?

        while index < nodes.count {
            let node = nodes[index]
            guard case let .tag(name, arguments, closing, dialect, range) = node else {
                result.append(node)
                index += 1
                continue
            }

            let normalized = name.lowercased()
            if closing {
                index += 1
                if normalized == expectedClose {
                    return SequenceResult(nodes: result, alternate: alternate, closingRange: range)
                }
                diagnostics.append(Diagnostic(message: "Unexpected closing tag \(name)", range: range))
                continue
            }

            if normalized == "else" {
                index += 1
                guard expectedClose == "if" else {
                    diagnostics.append(Diagnostic(message: "Else tag outside if block", range: range))
                    continue
                }
                let branch = buildSequence(until: "if")
                alternate = branch.nodes
                return SequenceResult(
                    nodes: result,
                    alternate: alternate,
                    closingRange: branch.closingRange
                )
            }

            guard Self.blockNames.contains(normalized) else {
                result.append(node)
                index += 1
                continue
            }

            index += 1
            let nested = buildSequence(until: normalized)
            let end = nested.closingRange?.end ?? range.end
            if nested.closingRange == nil {
                diagnostics.append(Diagnostic(message: "Unclosed \(name) block", range: range))
            }
            result.append(.block(
                name: name,
                arguments: arguments,
                body: nested.nodes,
                alternate: nested.alternate,
                dialect: dialect,
                range: SourceRange(start: range.start, end: end)
            ))
        }

        return SequenceResult(nodes: result, alternate: alternate, closingRange: nil)
    }

    private static let blockNames: Set<String> = [
        "if", "inline", "records", "rows", "loop", "iterate", "while", "define", "protect",
    ]
}

private struct SequenceResult {
    let nodes: [LassoNode]
    let alternate: [LassoNode]?
    let closingRange: SourceRange?
}
