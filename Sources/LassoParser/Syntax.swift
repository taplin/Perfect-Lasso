public struct SourcePosition: Equatable, Sendable {
    public let offset: Int
    public let line: Int
    public let column: Int

    public init(offset: Int, line: Int, column: Int) {
        self.offset = offset
        self.line = line
        self.column = column
    }
}

public struct SourceRange: Equatable, Sendable {
    public let start: SourcePosition
    public let end: SourcePosition

    public init(start: SourcePosition, end: SourcePosition) {
        self.start = start
        self.end = end
    }
}

public enum LassoDialect: String, Equatable, Sendable {
    case template
    case lasso8
    case lasso9
}

public enum LassoDelimiter: String, Equatable, Sendable {
    case square
    case lasso
    case lassoscript
    case echo
}

public struct Diagnostic: Equatable, Sendable {
    public let message: String
    public let range: SourceRange
}

public struct LassoDocument: Equatable, Sendable {
    public let nodes: [LassoNode]
    public let diagnostics: [Diagnostic]
}

public enum VariableScope: Equatable, Sendable {
    case unscoped
    case global
    case local
}

public struct LassoArgument: Equatable, Sendable {
    public let label: String?
    public let value: LassoExpression

    public init(label: String? = nil, value: LassoExpression) {
        self.label = label
        self.value = value
    }
}

public indirect enum LassoExpression: Equatable, Sendable {
    case string(String)
    case integer(Int)
    case decimal(Double)
    case boolean(Bool)
    case null
    case variable(String, VariableScope)
    case identifier(String)
    case call(callee: LassoExpression, arguments: [LassoArgument])
    case member(base: LassoExpression, name: String, arguments: [LassoArgument]?)
    case unary(operator: String, value: LassoExpression)
    case binary(left: LassoExpression, operator: String, right: LassoExpression)
    case assignment(target: LassoExpression, value: LassoExpression)
    case unknown(String)
}

public indirect enum LassoNode: Equatable, Sendable {
    case text(String, SourceRange)
    case expression(LassoExpression, LassoDialect, LassoDelimiter, SourceRange)
    case tag(name: String, arguments: [LassoArgument], closing: Bool, dialect: LassoDialect, range: SourceRange)
    case code([LassoExpression], LassoDialect, LassoDelimiter, SourceRange)
    case block(
        name: String,
        arguments: [LassoArgument],
        body: [LassoNode],
        alternate: [LassoNode]?,
        dialect: LassoDialect,
        range: SourceRange
    )
}
