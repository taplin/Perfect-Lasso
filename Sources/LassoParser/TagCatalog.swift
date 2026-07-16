/// Single source of truth for which tags are recognized as blocks (and in
/// which bare/no-parens form) by each of the three parsing stages that used
/// to each keep their own hand-synced `Set<String>` — `ScriptBodyParser`,
/// `BlockBuilder`, and `LassoParser` (bracket-mode). Those three sets are
/// NOT the same list under a different name: each stage has a genuinely
/// different responsibility, so a tag can legitimately be a "block" in one
/// stage and handled by a dedicated, separate code path in another (see
/// `CatalogScope`'s doc below). This catalog exists to make those
/// differences explicit and impossible to accidentally drift out of sync,
/// not to force them into one flat, incorrect answer.
///
/// This is Commit A of the tag-form consolidation project (see
/// `Documentation/` for the design/plan/review write-ups) — a pure data
/// refactor. It reproduces today's five `Set<String>` tables exactly; no
/// parsing/dispatch behavior changes. Commit B (a follow-up) will route
/// `if` and bare `records`/`rows` through an exhaustive `TagOpenForm`
/// switch built on top of this catalog; every other tag is unaffected by
/// either commit.
enum CatalogScope: CaseIterable {
    /// `ScriptBodyParser.blockNames`/`bareBlockNames` — script-mode
    /// (`<?lasso ... ?>`) block pairing. Tags with their own dedicated
    /// opener (`define`/`with`/`else`/`case`, each parsed by a distinct
    /// `parse*Opening`/`parse*Tag` function) are deliberately absent here;
    /// adding them would let the generic path double-handle what those
    /// functions already own.
    case scriptBody
    /// `BlockBuilder.blockNames` — nesting flat open/close tag pairs into
    /// real `.block` tree nodes. `select` is deliberately absent: it's
    /// special-cased *before* this membership check
    /// (`BlockBuilder.buildSequence`'s dedicated `normalized == "select"`
    /// branch, which lowers `Select`/`Case` into nested `if`), so adding it
    /// here would double-handle case-branch lowering.
    case blockBuilder
    /// `LassoParser`'s `blockTagNames`/`bareBlockTagNames` — bracket-mode
    /// (`[...]`) span routing. This is a broader net than the other two
    /// scopes: `else`/`case` belong here even though they are flat branch
    /// *separators*, not paired blocks, because this scope's question is
    /// "does a bracket span containing this call need block-aware
    /// (`ScriptBodyParser`) treatment instead of a plain expression?", not
    /// "is this a block" in the pairing sense the other two scopes mean.
    case lassoParser
}

/// One tag's participation across the three scopes above.
struct TagEntry {
    let name: String
    /// Scopes in which this name is recognized as block-shaped, per that
    /// scope's own meaning of the term (see `CatalogScope`'s cases).
    let blockScopes: Set<CatalogScope>
    /// Scopes in which this name additionally has a legitimate bare
    /// (zero-argument, no-parens) opening form. Not unified across scopes:
    /// `ScriptBodyParser`'s bare set is a real "needs zero arguments" list
    /// (`records`/`rows`'s implicit-source iteration, `inline`'s legacy
    /// colon-call, etc.); `LassoParser`'s bare set is `blockScopes[.lassoParser]
    /// minus "if"` for an unrelated reason (a bare `[if]`/`<!--[if IE 8]-->`
    /// has no sensible zero-argument meaning and was never valid syntax,
    /// unlike every other name in that scope's block set). Keeping these as
    /// two independently-declared sets (rather than one derived from the
    /// other) is deliberate — see each entry below for why they differ.
    let bareOpenScopes: Set<CatalogScope>
}

enum TagCatalog {
    static func entry(_ name: String) -> TagEntry? {
        shared[name.lowercased()]
    }

    static func isBlock(_ name: String, in scope: CatalogScope) -> Bool {
        entry(name)?.blockScopes.contains(scope) ?? false
    }

    static func allowsBareOpen(_ name: String, in scope: CatalogScope) -> Bool {
        entry(name)?.bareOpenScopes.contains(scope) ?? false
    }

    static let shared: [String: TagEntry] = Dictionary(uniqueKeysWithValues: entries.map { ($0.name, $0) })

    /// The full name × scope table, transcribed directly from the five
    /// `Set<String>` literals this replaces (verified against the current
    /// source, not re-derived from memory) — the union of every distinct
    /// name across all five is represented here exactly once.
    private static let entries: [TagEntry] = [
        // Ordinary control-flow/output blocks: recognized as a block in
        // all three scopes uniformly. `if` alone has no bare-open form in
        // any scope — a real Lasso `if` requires a condition; a bare
        // `[if]`/`[If IE 8]` (no parens at all) has no sensible
        // zero-argument meaning and was never valid syntax, unlike every
        // other name here, which allows bare-open in both scriptBody and
        // lassoParser. Found via a real corpus page
        // (templates/koi/master.template.lasso) whose HTML5-Boilerplate-
        // style IE conditional comments (`<!--[if IE 8]> ... <![endif]-->`)
        // were being misparsed as a real, always-present `if` block,
        // silently swallowing the entire page body until an unrelated
        // `[/if]` elsewhere happened to close it.
        TagEntry(name: "if", blockScopes: [.scriptBody, .blockBuilder, .lassoParser], bareOpenScopes: []),
        TagEntry(name: "inline", blockScopes: [.scriptBody, .blockBuilder, .lassoParser], bareOpenScopes: [.scriptBody, .lassoParser]),
        // `records`/`rows` need no arguments at all — real corpus:
        // includes/detail_a_sku.lasso's bare `records` ... `/records` (no
        // parens, no colon-call, just the identifier). Without bare-open
        // recognition, `parseBlockOpening` requires a `(` immediately
        // after the name and falls through, so `records` became a
        // meaningless bare top-level `.identifier` statement instead of a
        // real block opener — its "body" (everything up to `/records`)
        // ran as flat, un-looped top-level statements exactly once, using
        // whatever row the search's `Field()` cursor defaulted to,
        // instead of once per found row. On a real product detail page
        // this silently built a one-size dropdown instead of one option
        // per real SKU.
        TagEntry(name: "records", blockScopes: [.scriptBody, .blockBuilder, .lassoParser], bareOpenScopes: [.scriptBody, .lassoParser]),
        TagEntry(name: "rows", blockScopes: [.scriptBody, .blockBuilder, .lassoParser], bareOpenScopes: [.scriptBody, .lassoParser]),
        // loop/iterate/while/protect have no real bare-open form in
        // scriptBody (parseBlockOpening requires a `(` for these), but DO
        // qualify for lassoParser's bare-open set — that set is literally
        // "every lassoParser block name except if" (see the "if" entry's
        // comment above), not a curated list, so anything block-shaped in
        // lassoParser other than "if" belongs here too.
        TagEntry(name: "loop", blockScopes: [.scriptBody, .blockBuilder, .lassoParser], bareOpenScopes: [.lassoParser]),
        TagEntry(name: "iterate", blockScopes: [.scriptBody, .blockBuilder, .lassoParser], bareOpenScopes: [.lassoParser]),
        TagEntry(name: "while", blockScopes: [.scriptBody, .blockBuilder, .lassoParser], bareOpenScopes: [.lassoParser]),
        TagEntry(name: "protect", blockScopes: [.scriptBody, .blockBuilder, .lassoParser], bareOpenScopes: [.lassoParser]),
        TagEntry(name: "output_none", blockScopes: [.scriptBody, .blockBuilder, .lassoParser], bareOpenScopes: [.scriptBody, .lassoParser]),
        TagEntry(name: "html_comment", blockScopes: [.scriptBody, .blockBuilder, .lassoParser], bareOpenScopes: [.scriptBody, .lassoParser]),
        TagEntry(name: "encode_set", blockScopes: [.scriptBody, .blockBuilder, .lassoParser], bareOpenScopes: [.scriptBody, .lassoParser]),

        // select: a block in scriptBody (no dedicated opener there, so it
        // needs the generic path) and lassoParser (span routing), but NOT
        // blockBuilder, where it's special-cased ahead of the membership
        // check (see CatalogScope.blockBuilder's doc).
        TagEntry(name: "select", blockScopes: [.scriptBody, .lassoParser], bareOpenScopes: [.lassoParser]),

        // define_tag/define_type: the legacy colon-call form
        // (`Define_Tag: 'name', ...;`). Only ever reached via
        // ScriptBodyParser's bare-call path (never a "block" there in the
        // paired-opener sense — parseDefineOpening owns the modern
        // `define name(...) => {}` form separately) and via BlockBuilder's
        // pairing. Absent from lassoParser entirely — no real corpus
        // evidence of this legacy form inside a bracket span.
        TagEntry(name: "define_tag", blockScopes: [.blockBuilder], bareOpenScopes: [.scriptBody]),
        TagEntry(name: "define_type", blockScopes: [.blockBuilder], bareOpenScopes: [.scriptBody]),

        // define: the modern paren-call form has its own dedicated
        // ScriptBodyParser.parseDefineOpening (not the generic path, hence
        // absent from scriptBody's block set here), but still needs
        // blockBuilder pairing and lassoParser span-routing/bare-open
        // recognition for the bracket-mode dialect.
        TagEntry(name: "define", blockScopes: [.blockBuilder, .lassoParser], bareOpenScopes: [.lassoParser]),

        // with: has its own dedicated ScriptBodyParser.parseWithOpening
        // (absent from scriptBody's block set for the same reason as
        // define above) and no real corpus evidence of bracket-mode usage
        // at all, so absent from lassoParser entirely.
        TagEntry(name: "with", blockScopes: [.blockBuilder], bareOpenScopes: []),

        // else/case: flat branch separators, not paired blocks — each has
        // its own dedicated ScriptBodyParser function (parseElseTag/
        // parseCaseTag) and BlockBuilder never treats them as a
        // block-to-pair (else is consumed by the "if" pairing it belongs
        // to; case is split out of a select's body after the fact). Only
        // lassoParser's broader "does this bracket span need block-aware
        // treatment" question includes them.
        TagEntry(name: "else", blockScopes: [.lassoParser], bareOpenScopes: [.lassoParser]),
        TagEntry(name: "case", blockScopes: [.lassoParser], bareOpenScopes: [.lassoParser]),
    ]
}
