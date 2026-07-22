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
    /// `isQuoted` distinguishes `.name`/`->name` (bareword) from
    /// `.'name'`/`->'name'` (single-quoted) member access — a REAL,
    /// documented Lasso semantic (Ch. "Types" > "Custom Getters and
    /// Setters": "Within a manual getter or setter, it is vital to refer
    /// to the data member using the single-quoted name syntax.
    /// Otherwise, an infinite recursion situation may arise as the
    /// getter/setter continually re-calls itself"), not merely a lexical
    /// styling choice — quoted access bypasses a same-named custom
    /// getter/setter method entirely and goes straight to the raw stored
    /// field. `Evaluator.member(_:_:_:)` (reads) and
    /// `Evaluator.assign(_:to:defaultScope:)` (writes) both check this
    /// flag before ever consulting `context.tagRegistry`'s custom-method
    /// dispatch for `.object` values.
    case member(base: LassoExpression, name: String, arguments: [LassoArgument]?, isQuoted: Bool)
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
    /// Stage 8.4 added `group by`. Stage 8.5 (the last piece of the
    /// Captures subsystem plan) generalizes `withClauses` from a single
    /// `(variable, source)` pair to an ARRAY of them ("multiple with
    /// clauses define a nesting of iterations" — a later clause's source
    /// can reference an earlier clause's variable), and separately adds
    /// the `to`/`by` `generateSeries` literal syntax (desugared at parse
    /// time into an ordinary `generateSeries(...)` call — see
    /// `ExpressionParser.tryParseQueryWithClause`) plus a narrow,
    /// concrete `->eachCharacter` resolution of the docs' own
    /// "Making an Object Queriable"/`eacher` worked example (see
    /// `Evaluator.member(_:_:_:)`'s own `"eachcharacter"` case for why
    /// the FULLY general `eacher()` free-function + escaped-method-
    /// reference mechanism itself remains out of scope).
    case queryExpression(withClauses: [QueryWithClause], operations: [QueryOperation], action: QueryAction)
    /// `define [TypeName->]name(params) => body` used in EXPRESSION
    /// position, not just as its own top-level statement
    /// (`ScriptBodyParser.parseDefineOpening`). Ch. "Methods" > "Type
    /// Binding": a bound signature `type_name->method_name(...)`
    /// "cannot be called except with a target instance of type_name" --
    /// real corpus (zeroloop/ds's activerow.lasso) uses this bound form
    /// as the ACTION of a ternary, a guarded monkey-patch that should
    /// only register the method if the target type actually exists:
    /// `::json_encode->istype ? define json_encode->encodeValue(p::activerow) => .encodeValue(#p->asmap)`.
    /// `boundType` is `nil` for an ordinary unbound `define name(...) => body`
    /// (registers a ordinary custom tag, same as the statement form).
    /// Return-type constraints (`::ReturnType`) are parsed and discarded,
    /// matching the statement-level `define`'s own existing behavior --
    /// this codebase enforces no return-type constraints anywhere.
    case definition(boundType: String?, name: String, parameters: [LassoArgument], body: [LassoNode])
    case unknown(String)
}

/// One `with NAME in SOURCE` clause (Ch. "Query Expressions", "The With
/// Clause") — see `LassoExpression.queryExpression`'s own doc comment
/// for how an array of these models "multiple with clauses" (Stage 8.5).
public struct QueryWithClause: Equatable, Sendable {
    public let variable: String
    public let source: LassoExpression

    public init(variable: String, source: LassoExpression) {
        self.variable = variable
        self.source = source
    }
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
    /// `group OBJECT by KEY into NAME` (Ch. "Query Expressions", "Group
    /// By") — Stage 8.4. Real Lasso: "a group by consists of three
    /// elements: the object going into the group, the key by which the
    /// objects are grouped, and a new local variable name." Unlike every
    /// OTHER operation, this one REPLACES the entire row variable set
    /// going forward with just `into` — "from this point forward, no
    /// previously introduced variables are available. Only [the new
    /// name] exists now."
    case groupBy(objectExpression: LassoExpression, keyExpression: LassoExpression, into: String)
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
