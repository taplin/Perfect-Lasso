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
    /// A Lasso 9 Capture literal (`{ ... }`/auto-collect `{^ ... ^}`) —
    /// see `Captures.swift`'s own doc comment. `body` is already fully
    /// parsed (via the same ScriptBodyParser + BlockBuilder pipeline
    /// every other nested block body in this parser uses) at the point
    /// this expression node is constructed.
    case captureLiteral(body: [LassoNode], autoCollect: Bool)
    /// A Lasso 9 Query Expression's `with` clause (Ch. "Query
    /// Expressions", lassoguide.com/language/query-expressions.html) —
    /// `with NAME in SOURCE select EXPR` / `with NAME in SOURCE do
    /// (EXPR|CAPTURE)`. A SEPARATE, additive construct from the
    /// pre-existing `with NAME in EXPR do { body }` STATEMENT/block form
    /// (`ScriptBodyParser.parseWithOpening`/`Renderer.swift`'s own
    /// `case "with":`) — that one is a narrower, real-corpus-driven
    /// block-body iteration tag, untouched by this addition; this case
    /// is recognized only in EXPRESSION position (assignable, nestable,
    /// matching the real docs' "query expressions can be treated as
    /// objects"), and only for the bare-expression/capture-value form of
    /// `do` the block-tag form doesn't accept at all (see
    /// `ExpressionParser`'s own `with`-recognition doc comment for the
    /// exact non-overlapping boundary between the two).
    ///
    /// Stage 8.1 added the core `with...select`/`with...do` pipeline
    /// (single with-clause, `select`/`do` actions only). Stage 8.2 added
    /// `operations` — `where`/`let`/`skip`/`take` clauses (Ch. "Query
    /// Expressions", "Operations"), applied IN THE ORDER WRITTEN between
    /// the with-clause and the action (real Lasso's own worked examples
    /// show `skip`/`take`'s relative order changing the result — `take 4
    /// skip 3` vs `skip 3 take 4` — so this is a real sequential
    /// pipeline, not a set of independent filters). Stage 8.3 added the
    /// `order by` operation and the `sum`/`average`/`min`/`max` actions.
    /// Still no `group by` operation or comma-separated multi with-clause
    /// nesting — each a later stage's own addition, per
    /// `Documentation/captures-subsystem-plan.md`'s Stage 8 breakdown.
    case queryExpression(variable: String, source: LassoExpression, operations: [QueryOperation], action: QueryAction)
    case unknown(String)
}

/// The action ending a Query Expression (Ch. "Query Expressions",
/// "Actions") — see `LassoExpression.queryExpression`'s own doc comment
/// for this stage's scope. `perform` corresponds to the real `do`
/// keyword (`do` is a Swift reserved word). Stage 8.3 adds `sum`/
/// `average`/`min`/`max` — each reduces the surviving rows to a single
/// value via a single expression, evaluated once per row.
public enum QueryAction: Equatable, Sendable {
    case select(LassoExpression)
    case perform(LassoExpression)
    case sum(LassoExpression)
    case average(LassoExpression)
    case min(LassoExpression)
    case max(LassoExpression)
}

/// A Query Expression operation (Ch. "Query Expressions", "Operations")
/// — see `LassoExpression.queryExpression`'s own doc comment for scope.
/// `filter` corresponds to the real `where` keyword (`where` is a Swift
/// keyword, reserved for pattern-match guards). Stage 8.3 adds
/// `orderBy` (the real `order by` operation, two words) — one or more
/// comma-separated `(key expression, direction)` pairs, evaluated per
/// row and used to sort the surviving row list.
public enum QueryOperation: Equatable, Sendable {
    case filter(LassoExpression)
    case `let`(name: String, value: LassoExpression)
    case skip(LassoExpression)
    case take(LassoExpression)
    case orderBy([QueryOrderKey])
}

/// One `order by` sort key (Ch. "Query Expressions", "Order By") —
/// `descending` defaults to `false` ("when a direction is not
/// specified, ascending order is assumed").
public struct QueryOrderKey: Equatable, Sendable {
    public let expression: LassoExpression
    public let descending: Bool

    public init(expression: LassoExpression, descending: Bool) {
        self.expression = expression
        self.descending = descending
    }
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
