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
    /// Tag-open-form recognition counts from this parse (Phase 3 of tag-form
    /// consolidation). Deliberately no default value: every construction
    /// site must supply it explicitly, so a future site that forgets to
    /// thread real counts through fails to compile instead of silently
    /// producing an empty-but-plausible-looking document.
    public let openFormFires: [TagOpenFormFire: Int]
}

public enum LassoMemberVisibility: String, Equatable, Sendable {
    case `public`
    case `protected`
    case `private`
}

public struct LassoDataMemberDefinition: Equatable, Sendable {
    public let name: String
    public let typeConstraint: String?
    public let defaultValue: LassoExpression?
    public let visibility: LassoMemberVisibility?

    public init(
        name: String,
        typeConstraint: String?,
        defaultValue: LassoExpression?,
        visibility: LassoMemberVisibility?
    ) {
        self.name = name
        self.typeConstraint = typeConstraint
        self.defaultValue = defaultValue
        self.visibility = visibility
    }
}

public struct LassoMethodDefinition: Equatable, Sendable {
    public let name: String
    public let parameters: [LassoArgument]
    public let returnType: String?
    public let visibility: LassoMemberVisibility
    public let body: [LassoNode]

    public init(
        name: String,
        parameters: [LassoArgument],
        returnType: String?,
        visibility: LassoMemberVisibility,
        body: [LassoNode]
    ) {
        self.name = name
        self.parameters = parameters
        self.returnType = returnType
        self.visibility = visibility
        self.body = body
    }
}

public struct LassoTypeDefinition: Equatable, Sendable {
    public let name: String
    public let dataMembers: [LassoDataMemberDefinition]
    public let methods: [LassoMethodDefinition]

    public init(
        name: String,
        dataMembers: [LassoDataMemberDefinition],
        methods: [LassoMethodDefinition]
    ) {
        self.name = name
        self.dataMembers = dataMembers
        self.methods = methods
    }
}

public enum VariableScope: Equatable, Sendable {
    case unscoped
    // Despite the name, this is PAGE-scoped storage — what `[Variable]`/
    // `[Var]`/`$name` read and write (Lasso 8.5 Language Guide Ch. 15
    // Table 1 "Page Variable Tags"). The naming predates `.trueGlobal`
    // below and is kept as-is rather than renamed, to avoid an
    // unrelated blast-radius change across every existing call site.
    case global
    case local
    // A genuinely separate namespace from `.global` above — Ch. 15
    // Table 3 "Global Tags": "The globals tags allow direct access to
    // global variables from any environment." Backed by its own
    // dictionary (`LassoContext.trueGlobals`), not `.global`'s, so a
    // page `Variable` and a true `Global` can share the same NAME
    // without colliding, matching real Lasso keeping the two
    // namespaces separate. Scoped to the lifetime of one `LassoContext`
    // (one page render) rather than truly persisting server-wide
    // across requests — this interpreter has no cross-request process
    // state anywhere else either, so that part of the real semantics is
    // knowingly out of scope here.
    case trueGlobal
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
    case void
    case variable(String, VariableScope)
    case identifier(String)
    /// `\identifier` (Ch. 30 Table 21) — a reference to an already-
    /// defined tag (built-in or custom), evaluated to a passable value
    /// rather than invoked. See `Evaluator.evaluate(_:)`'s own case for
    /// how this resolves.
    case tagReference(String)
    case call(callee: LassoExpression, arguments: [LassoArgument])
    case member(base: LassoExpression, name: String, arguments: [LassoArgument]?)
    case unary(operator: String, value: LassoExpression)
    case binary(left: LassoExpression, operator: String, right: LassoExpression)
    case assignment(target: LassoExpression, value: LassoExpression)
    case ternary(condition: LassoExpression, whenTrue: LassoExpression, whenFalse: LassoExpression)
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
    case typeDefinition(LassoTypeDefinition, LassoDialect, SourceRange)

    /// Every case's trailing `SourceRange` — used to attach a "failed at
    /// line N" location to a render error at the point it's first thrown,
    /// before any unwinding. See `RendererEngine.render(_:)`.
    public var range: SourceRange {
        switch self {
        case let .text(_, range),
             let .expression(_, _, _, range),
             let .tag(_, _, _, _, range),
             let .code(_, _, _, range),
             let .block(_, _, _, _, _, range),
             let .typeDefinition(_, _, range):
            range
        }
    }
}
