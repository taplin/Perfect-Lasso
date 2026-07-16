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
                if arguments.isEmpty {
                    // A bare `else` (no condition) is the unconditional
                    // final branch — nothing further to nest.
                    alternate = branch.nodes
                } else {
                    // `else(condition)` — real Lasso 8's if-else-if
                    // chaining (`if(A) ... else(B) ... else(C) ... else
                    // ... /if`). This must become NESTED if/else, not a
                    // flat alternate: previously this branch discarded
                    // `arguments` (the condition) entirely and returned
                    // immediately with `alternate: branch.nodes`, which
                    // silently dropped `branch.alternate` — meaning any
                    // `else(condition)` behaved exactly like an
                    // unconditional `else` (always "true"), and every
                    // branch past the *second* one (any further
                    // `else(condition)`/final `else`) was lost from the
                    // tree entirely. Real corpus:
                    // components/koi_setup.inc's environment-detection
                    // chain (`if(server_name >> 'www2' ...) ... else
                    // (server_name >> 'www3' ...) ... else(...) ... else
                    // ... /if`) always picked the second branch
                    // regardless of `server_name`'s real value.
                    alternate = [.block(
                        name: "if",
                        arguments: arguments,
                        body: branch.nodes,
                        alternate: branch.alternate,
                        dialect: dialect,
                        range: SourceRange(start: range.start, end: branch.closingRange?.end ?? range.end)
                    )]
                }
                return SequenceResult(
                    nodes: result,
                    alternate: alternate,
                    closingRange: branch.closingRange
                )
            }

            if normalized == "select" {
                index += 1
                let selectValue = arguments.first?.value ?? .null
                let body = buildSequence(until: "select")
                if body.closingRange == nil {
                    diagnostics.append(Diagnostic(message: "Unclosed select block", range: range))
                }
                let branches = Self.splitIntoCaseBranches(body.nodes)
                result.append(contentsOf: Self.lowerSelectCase(
                    selectValue: selectValue,
                    branches: branches,
                    dialect: dialect,
                    range: range
                ))
                continue
            }

            guard TagCatalog.isBlock(normalized, in: .blockBuilder) else {
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

    /// Splits a `[Select]...[/Select]` body (already fully block-paired by
    /// `buildSequence` — any nested `if`/`loop`/etc. inside a `Case` branch
    /// is already a real `.block` node by the time this runs, since `case`
    /// isn't recognized as a `.blockBuilder`-scope block and so never
    /// interrupts that recursion) on its
    /// top-level `case` tag markers. `value == nil` marks a bare `[Case]`
    /// (Lasso 8.5: "a [Case] tag without any value is used as the default
    /// value... the first [Case] tag without any value is returned as the
    /// default"), so everything from the first bare `Case` onward is
    /// truncated to exactly that one branch — matching the doc's own
    /// stated tie-break, not left to incidental parser behavior. Content
    /// before the first `Case` tag (a body with no real corpus precedent)
    /// is discarded, matching every real corpus `[Select]` example, which
    /// always opens directly with a `Case`.
    private static func splitIntoCaseBranches(_ flatBody: [LassoNode]) -> [(value: LassoExpression?, body: [LassoNode])] {
        var branches: [(value: LassoExpression?, body: [LassoNode])] = []
        var currentValue: LassoExpression?
        var currentBody: [LassoNode] = []
        var sawCase = false

        for node in flatBody {
            if case let .tag(name, arguments, false, _, _) = node, name.lowercased() == "case" {
                if sawCase {
                    branches.append((currentValue, currentBody))
                }
                currentValue = arguments.first?.value
                currentBody = []
                sawCase = true
                continue
            }
            currentBody.append(node)
        }
        if sawCase {
            branches.append((currentValue, currentBody))
        }

        if let defaultIndex = branches.firstIndex(where: { $0.value == nil }) {
            branches.removeSubrange((defaultIndex + 1)...)
        }
        return branches
    }

    /// Lowers `Select`/`Case` branches into the existing `if`/`else if`/
    /// `else` block representation — no new AST node, no new runtime code.
    /// Select/Case is structurally an N-way `if` chain (test the select
    /// value once per branch in order, first match wins, optional
    /// default), so reusing `if`'s exact execution path
    /// (`Renderer.swift`'s `renderBlock`, `case "if"`) gets correct
    /// "value substituted as output" behavior and correct case-match
    /// semantics for free: each comparison becomes a literal
    /// `.binary(selectValue, "==", caseValue)` node, evaluated by
    /// `Evaluator.binary`'s existing coercive/string-based `"=="` — the
    /// same equality every other `==` in this language already uses, not
    /// an invented comparison rule. See
    /// Documentation/legacy-define-tag-type-plan.md's "lower into the same
    /// models already used by modern syntax" principle.
    private static func lowerSelectCase(
        selectValue: LassoExpression,
        branches: [(value: LassoExpression?, body: [LassoNode])],
        dialect: LassoDialect,
        range: SourceRange
    ) -> [LassoNode] {
        var tail: [LassoNode] = []
        var conditional = branches[...]
        if let last = branches.last, last.value == nil {
            tail = last.body
            conditional = branches[..<(branches.count - 1)]
        }

        var lowered = tail
        for branch in conditional.reversed() {
            guard let value = branch.value else { continue }
            lowered = [.block(
                name: "if",
                arguments: [LassoArgument(value: .binary(left: selectValue, operator: "==", right: value))],
                body: branch.body,
                alternate: lowered,
                dialect: dialect,
                range: range
            )]
        }
        return lowered
    }
}

private struct SequenceResult {
    let nodes: [LassoNode]
    let alternate: [LassoNode]?
    let closingRange: SourceRange?
}
