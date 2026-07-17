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
/// Tag-form consolidation status:
/// - **Phase 1** (Commit A: catalog as a pure data refactor reproducing the
///   five original `Set<String>` tables exactly, no behavior change; Commit
///   B: routed `if` through an exhaustive `TagOpenForm` switch in
///   `ScriptBodyParser` — `classifyIfOpen`/`parseIfOpening` — the one tag
///   with a genuine surface-form ambiguity reached by a fallible cascade,
///   where a missing case previously meant silent wrong output, not an
///   error. **Correction** (found during the Phase 3 design-panel review,
///   2026-07-16): `records`/`rows`'s `.bareIdentifier` form is documented
///   in this catalog but was never routed through a dedicated switch of its
///   own — both names reach the same generic, non-form-differentiating
///   cascades every other bare-open tag does (`parseBlockOpening`'s
///   colon-then-paren cascade; `emitStatement`'s
///   `TagCatalog.allowsBareOpen`-gated cascade). A dedicated case there
///   would only reproduce what those generic paths already do — which is
///   exactly why Phase 1's own Swift-expert review had the redundant
///   records/rows case in `emitStatement` removed after an earlier draft
///   added it (see that function's history). This file's `openForms` entry
///   for `records`/`rows` remains accurate as documentation; only this
///   comment's claim that a switch dispatches on it was wrong.
/// - **Phase 2** (this state): re-examined all 15 remaining tags against
///   Phase 1's real lesson and found NONE of them have that same kind of
///   ambiguity — every one either collapses to identical shared-cascade
///   handling regardless of which attested form matched (`inline`, `loop`,
///   `iterate`, `encode_set`), has no cascade-reachable form worth
///   characterizing at all (`while`, `protect`, `html_comment`,
///   `output_none`), or already has its own genuinely-divergent handling
///   solved elsewhere by dedicated, non-`TagOpenForm` code
///   (`select`/`case`'s branch-lowering in `BlockBuilder`, `else`'s
///   bare-vs-condition branching, `define`/`define_tag`/`define_type`/
///   `with`'s dedicated opener functions). So Phase 2 is deliberately a
///   documentation-only change: every entry's `openForms` is now populated
///   with real, corpus-verified evidence (or left `[]` with an explicit
///   architectural reason, never "not yet characterized") — no new
///   dispatch machinery, because none of the 15 earned it. Building a
///   records/rows-style switch for any of them would have been ceremony
///   over a tautology, the exact mistake Phase 1's own review process
///   caught and fixed.
/// - **Phase 3** (shipped): live-server fire-count instrumentation recording
///   which real `TagOpenForm` each tag was actually recognized with during
///   real rendering — see `TagOpenFormCounters.swift`. Left one known gap
///   unresolved at the time: `inline`'s, `encode_set`'s, and
///   `define_tag`'s/`define_type`'s real bare colon-call forms had no
///   `TagOpenForm` case representing them at all, and (found investigating
///   that gap) `iterate`'s/`while`'s real paren-less-colon usage and
///   `protect`'s real bare usage weren't even recognized as block openers
///   in `scriptBody` at all — a genuine parsing bug, not just a missing
///   taxonomy entry (see Phase 4).
/// - **Phase 4**: fixed the `iterate`/`while`/`protect` script-mode
///   block-pairing bug this file's own Phase 2/3 comments had documented as
///   merely "currently-unhandled" — real corpus `iterate: vars, local:'i';`
///   (components/inSite/tables.inc) and `while: #url_string >> '++';`
///   (components/inSite/urlencode.inc) were falling all the way through
///   `parseBlockOpening` (which requires a `(` immediately after an
///   optional colon) into `emitStatement`, where `allowsBareOpen` was
///   `false` for these three names — so the whole `tagname: args;` or bare
///   `tagname` statement became a meaningless flat `.code(...)` expression
///   instead of a real `.tag(..., closing: false, ...)` opener, and
///   `BlockBuilder` could never pair it with its real `/tagname;` closer
///   (confirmed live: `_botscript.lasso`'s bare `protect ... /protect`,
///   real corpus, wasn't actually wrapping anything in error protection at
///   all). Fixed by widening `iterate`/`while`/`protect`'s
///   `bareOpenScopes` to include `.scriptBody`, exactly like
///   `inline`/`encode_set` already did — no new dispatch code needed, since
///   `emitStatement`'s existing generic `allowsBareOpen`-gated cascade
///   already does the right thing once the catalog says these names
///   qualify. Also introduced `TagOpenForm.bareColonCall` (a real, distinct
///   shape from `.colonCall`, which means colon-WITH-parens) to finally
///   characterize the colon-plus-arguments-no-parens form `iterate`/
///   `while`/`inline`/`encode_set`/`define_tag`/`define_type` all share,
///   closing the gap Phase 3 left open — `protect`'s bare zero-arg form
///   reuses the existing `.bareIdentifier` case instead (same shape
///   `records`/`rows` already have).
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

/// The finite set of ways a tag can open, in the ScriptBodyParser (script-
/// mode) grammar. Not a global "every form in the language" enumeration —
/// each `TagEntry.openForms` lists only the forms THAT tag actually
/// supports, with the canonical Lasso 9 form always listed first, so a
/// classifier can try it first and never pay a legacy-form probing cost on
/// modern input.
// `public`: Phase 3's fire-count reporting (`TagOpenFormFire.form` in
// `TagOpenFormCounters.swift`, read from `LassoPerfectServer/main.swift`
// across the module boundary) needs this type and its `displayName`.
// `TagCatalog`/`TagEntry`/`CatalogScope` stay internal — nothing else
// outside `LassoParser` needs them.
public enum TagOpenForm: Hashable, Sendable {
    /// `if(cond)` / `inline(...)` — the canonical, modern Lasso 9 shape.
    case parenCall
    /// `if:(cond)` — Lasso 8's legacy colon-call convention.
    case colonCall
    /// `if cond { ... }` — no parens, no colon, terminated by a brace body
    /// with no `=>` arrow either. Real corpus:
    /// components/site_setup_tags.inc's `excludeBots`. Only `if` has real
    /// corpus evidence of this shape.
    case bareCondition
    /// `records` / `rows` — zero arguments, no parens at all. For
    /// `records`/`rows` specifically the (absent) argument list would
    /// otherwise come from the enclosing `inline`'s result; `protect`
    /// shares this same zero-arg, no-parens, no-colon shape but simply
    /// never takes arguments at all.
    case bareIdentifier
    /// `iterate: vars, local('i');` / `inline: -database=...;` — Lasso 8's
    /// colon-call convention with NO enclosing parens at all (distinct from
    /// `.colonCall`, which means colon-WITH-parens, `if:(cond)`). Real
    /// corpus: components/inSite/tables.inc's `iterate: vars, local:'i'`,
    /// components/inSite/urlencode.inc's `while: #url_string >> '++'`,
    /// pages_internal/categories.lasso's `inline: -database=...`,
    /// includes/coupon.include.lasso's `Encode_Set: -EncodeNone`,
    /// components/js_timer.inc's `define_type: 'js_timer', 'integer',
    /// -prototype;`. Reached only via `emitStatement`'s bare-open path,
    /// never `parseBlockOpening`'s cascade (which requires `(` immediately
    /// after an optional colon).
    case bareColonCall

    /// Human-readable label for fire-count reports (Phase 3). An exhaustive
    /// switch, deliberately: one more forced compile-error site alongside
    /// `TagCatalog`'s `openForms` array literals and `parseIfOpening`'s
    /// classifier switch if a case is ever retired.
    public var displayName: String {
        switch self {
        case .parenCall: return "parenCall"
        case .colonCall: return "colonCall"
        case .bareCondition: return "bareCondition"
        case .bareIdentifier: return "bareIdentifier"
        case .bareColonCall: return "bareColonCall"
        }
    }
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
    /// The script-mode opening forms this tag actually supports, canonical
    /// form first. `ScriptBodyParser.parseBlockOpening`/`emitStatement` only
    /// dispatch on this for "if" and "records"/"rows" (Phase 1) — every
    /// other entry's `openForms` (Phase 2) is populated as pure,
    /// corpus-verified documentation, deliberately not read by any switch,
    /// so this field never silently asserts dispatch behavior that doesn't
    /// exist. An empty `[]` always means "no cascade-reachable form worth
    /// characterizing," never "not yet characterized" — see each entry's
    /// comment for the specific architectural reason.
    let openForms: [TagOpenForm]
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
        // `[/if]` elsewhere happened to close it. `.bareColonCall`
        // (`if: cond; ... /if;`, the classic Lasso 8 slash-closed form —
        // importscripts/*.lasso and 6 other real pages) and `.bareCondition`
        // are both dispatched through `parseIfOpening`'s own classifier,
        // not the shared `bareOpenScopes` cascade — "if" stays deliberately
        // isolated from that cascade (see `parseBlockOpening`'s comment)
        // since its else-chaining pairing logic is genuinely more delicate
        // than any other name here.
        TagEntry(name: "if", blockScopes: [.scriptBody, .blockBuilder, .lassoParser], bareOpenScopes: [], openForms: [.parenCall, .colonCall, .bareCondition, .bareColonCall]),
        // inline's paren-call form is real corpus (iscrubs/LassoEcho.lasso
        // and throughout). Its bare, paren-less colon-call form
        // (`inline: -database=...;`, pages_internal/categories.lasso) is a
        // DIFFERENT form than `.colonCall` (which means colon-WITH-parens,
        // matching `if:(cond)`) — it's `.bareColonCall` (Phase 4), reached
        // only via `emitStatement`'s bare-open path (`bareOpenScopes` above
        // already includes `.scriptBody`), never through
        // `parseBlockOpening`'s cascade.
        TagEntry(name: "inline", blockScopes: [.scriptBody, .blockBuilder, .lassoParser], bareOpenScopes: [.scriptBody, .lassoParser], openForms: [.parenCall, .bareColonCall]),
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
        TagEntry(name: "records", blockScopes: [.scriptBody, .blockBuilder, .lassoParser], bareOpenScopes: [.scriptBody, .lassoParser], openForms: [.parenCall, .colonCall, .bareIdentifier]),
        TagEntry(name: "rows", blockScopes: [.scriptBody, .blockBuilder, .lassoParser], bareOpenScopes: [.scriptBody, .lassoParser], openForms: [.parenCall, .colonCall, .bareIdentifier]),
        // loop's paren-call (pages_internal/categorize.lasso's `Loop(20)`)
        // AND colon-WITH-parens (pages/online_return_items.page.lasso's
        // `[Loop: ($no_of_items)]`) are both real — the only remaining
        // entry with two genuinely cascade-handled forms, matching `if`'s
        // shape but without a divergent-handling ambiguity worth its own
        // dispatch (both forms reach identical `readBalanced`/
        // `parseCallArguments` logic in `parseBlockOpening`). loop has no
        // real bare-open form in scriptBody (no paren-less colon usage
        // attested), but DOES qualify for lassoParser's bare-open set —
        // that set is literally "every lassoParser block name except if"
        // (see the "if" entry's comment above), not a curated list.
        TagEntry(name: "loop", blockScopes: [.scriptBody, .blockBuilder, .lassoParser], bareOpenScopes: [.lassoParser], openForms: [.parenCall, .colonCall]),
        // iterate's paren-call is real (_clear_cache.lasso's
        // `iterate(globals->keys, local(gkey))`). Its real corpus colon
        // usage (components/inSite/tables.inc's `iterate: vars,
        // local:'i'`) is paren-LESS — `.bareColonCall`, not `.colonCall`
        // (which means colon-WITH-parens). **Phase 4 bug fix**: this form
        // was previously NOT reaching `emitStatement`'s bare-open path at
        // all (`bareOpenScopes` lacked `.scriptBody`), so the whole
        // `iterate: vars, local:'i';` statement fell through to a
        // meaningless flat `.code(...)` expression instead of a real
        // `.tag(..., closing: false, ...)` opener — `BlockBuilder` could
        // never pair it with its real `/iterate;` closer, so the loop body
        // ran as flat top-level statements exactly once instead of once
        // per element. Fixed by adding `.scriptBody` here, matching
        // `inline`/`encode_set`'s existing bare-open recognition — no new
        // dispatch code needed, `emitStatement`'s existing generic cascade
        // already does the right thing once the catalog says so.
        TagEntry(name: "iterate", blockScopes: [.scriptBody, .blockBuilder, .lassoParser], bareOpenScopes: [.scriptBody, .lassoParser], openForms: [.parenCall, .bareColonCall]),
        // while has NO corpus evidence of a paren-call form at all — every
        // `while(` hit in the corpus is embedded JavaScript, not Lasso. Its
        // only real Lasso usage (components/inSite/urlencode.inc's
        // `while: #url_string >> '++';`, lp_string_firstwords.inc) is
        // paren-less colon — `.bareColonCall`. **Phase 4 bug fix**: same
        // block-pairing bug as `iterate` above (`bareOpenScopes` lacked
        // `.scriptBody`), fixed the same way.
        TagEntry(name: "while", blockScopes: [.scriptBody, .blockBuilder, .lassoParser], bareOpenScopes: [.scriptBody, .lassoParser], openForms: [.bareColonCall]),
        // protect's only attested corpus form is bare zero-arg `protect
        // ... /protect` (_botscript.lasso) — no paren or colon usage found
        // at all, so `.bareIdentifier` (the same zero-arg shape
        // `records`/`rows` use) is the only real form. **Phase 4 bug fix**:
        // same block-pairing bug as `iterate`/`while` above (`bareOpenScopes`
        // lacked `.scriptBody`) — confirmed live in the real corpus:
        // `_botscript.lasso`'s bare `protect ... /protect` wasn't actually
        // pairing at all, so its body wasn't wrapped in error protection.
        // Fixed the same way.
        TagEntry(name: "protect", blockScopes: [.scriptBody, .blockBuilder, .lassoParser], bareOpenScopes: [.scriptBody, .lassoParser], openForms: [.bareIdentifier]),
        // output_none's only attested form is bare zero-arg
        // (scrubsetc.lasso/utscrubs.lasso), already reached via
        // `emitStatement`'s bare-open path (`bareOpenScopes` above) — no
        // cascade-reachable open form to list here.
        TagEntry(name: "output_none", blockScopes: [.scriptBody, .blockBuilder, .lassoParser], bareOpenScopes: [.scriptBody, .lassoParser], openForms: []),
        // html_comment has no corpus attestation of any opening form at
        // all — retained as a block name from the original five sets, but
        // there's nothing real to characterize.
        TagEntry(name: "html_comment", blockScopes: [.scriptBody, .blockBuilder, .lassoParser], bareOpenScopes: [.scriptBody, .lassoParser], openForms: []),
        // encode_set's paren-call is real (iscrubs/LassoEcho.lasso's
        // `[Encode_Set(-EncodeNone)]`); its colon usage
        // (includes/coupon.include.lasso's `[Encode_Set: -EncodeNone]`) is
        // paren-less — `.bareColonCall`, same shape as inline's bare colon
        // form — reached via `emitStatement`'s bare-open path, not the
        // cascade.
        TagEntry(name: "encode_set", blockScopes: [.scriptBody, .blockBuilder, .lassoParser], bareOpenScopes: [.scriptBody, .lassoParser], openForms: [.parenCall, .bareColonCall]),

        // select: a block in scriptBody (no dedicated opener there, so it
        // needs the generic path) and lassoParser (span routing), but NOT
        // blockBuilder, where it's special-cased ahead of the membership
        // check (see CatalogScope.blockBuilder's doc). `openForms` is `[]`
        // deliberately, not "uncharacterized": select/case's real
        // complexity is branch-lowering in `BlockBuilder.buildSequence`
        // (`lowerSelectCase`/`splitIntoCaseBranches`) — an architecturally
        // different concern than "which surface form did this tag open
        // with," so `TagOpenForm` doesn't apply here at all.
        TagEntry(name: "select", blockScopes: [.scriptBody, .lassoParser], bareOpenScopes: [.lassoParser], openForms: []),

        // define_tag/define_type: the legacy colon-call form
        // (`Define_Tag: 'name', ...;`, components/js_timer.inc's
        // `define_type: 'js_timer', 'integer', -prototype;`). Only ever
        // reached via ScriptBodyParser's bare-call path (never a "block"
        // there in the paired-opener sense — parseDefineOpening owns the
        // modern `define name(...) => {}` form separately) and via
        // BlockBuilder's pairing. Absent from lassoParser entirely — no
        // real corpus evidence of this legacy form inside a bracket span.
        // This bare colon-call is `.bareColonCall`, the same category as
        // inline's bare form (reached via `emitStatement`'s bare-open path,
        // not the `parseBlockOpening` cascade).
        TagEntry(name: "define_tag", blockScopes: [.blockBuilder], bareOpenScopes: [.scriptBody], openForms: [.bareColonCall]),
        TagEntry(name: "define_type", blockScopes: [.blockBuilder], bareOpenScopes: [.scriptBody], openForms: [.bareColonCall]),

        // define: the modern paren-call form has its own dedicated
        // ScriptBodyParser.parseDefineOpening (not the generic path, hence
        // absent from scriptBody's block set here), but still needs
        // blockBuilder pairing and lassoParser span-routing/bare-open
        // recognition for the bracket-mode dialect. `openForms` is `[]`:
        // parseDefineOpening already dispatches its own genuinely-divergent
        // body shapes (`=> type {}`/`=> {}`/`=> expr`) via real computed
        // checks — a different, already-solved consolidation concern that
        // predates and doesn't need `TagOpenForm`.
        TagEntry(name: "define", blockScopes: [.blockBuilder, .lassoParser], bareOpenScopes: [.lassoParser], openForms: []),

        // with: has its own dedicated ScriptBodyParser.parseWithOpening
        // (absent from scriptBody's block set for the same reason as
        // define above) and no real corpus evidence of bracket-mode usage
        // at all, so absent from lassoParser entirely. `openForms` is `[]`:
        // there is only one real form (`with name in expr do { }`), so
        // there's no ambiguity for `TagOpenForm` to characterize.
        TagEntry(name: "with", blockScopes: [.blockBuilder], bareOpenScopes: [], openForms: []),

        // else/case: flat branch separators, not paired blocks — each has
        // its own dedicated ScriptBodyParser function (parseElseTag/
        // parseCaseTag) and BlockBuilder never treats them as a
        // block-to-pair (else is consumed by the "if" pairing it belongs
        // to; case is split out of a select's body after the fact). Only
        // lassoParser's broader "does this bracket span need block-aware
        // treatment" question includes them. `openForms` is `[]`: `else`'s
        // real divergence (bare `else` vs. `else(condition)` chain-nesting —
        // real corpus: components/koi_setup.inc's environment-detection
        // chain, and the bug this exact ambiguity caused before it was
        // fixed) already lives as a genuine computed 2-way branch in
        // `BlockBuilder.buildSequence` (keyed on `arguments.isEmpty`), not
        // as a scriptBody *opening* form — `TagOpenForm` doesn't model it.
        TagEntry(name: "else", blockScopes: [.lassoParser], bareOpenScopes: [.lassoParser], openForms: []),
        TagEntry(name: "case", blockScopes: [.lassoParser], bareOpenScopes: [.lassoParser], openForms: []),
    ]
}
