import Foundation
import Testing
@testable import LassoParser

// Phase 3 of tag-form consolidation: fire-count instrumentation. These
// tests cover the store's own correctness, real recognition-site accuracy
// (including the deliberate documented gaps this phase leaves alone), and
// that fires genuinely fold up through every nesting path a real corpus
// file can take — defines, type methods, all four LassoParser bracket
// branches, and includes/libraries — since an under-counted fold site would
// silently misrepresent exactly the legacy-syntax-heavy files (library
// includes, startup components) this instrumentation exists to measure.

// MARK: - Store correctness

@Test func countingStoreAccumulatesAcrossMultipleMerges() {
    let store = CountingTagOpenFormCounterStore()
    let ifParen = TagOpenFormFire(tagName: "if", form: .parenCall)
    let loopColon = TagOpenFormFire(tagName: "loop", form: .colonCall)

    store.merge([ifParen: 3])
    store.merge([ifParen: 2, loopColon: 1])

    let snapshot = store.snapshot()
    #expect(snapshot[ifParen] == 5)
    #expect(snapshot[loopColon] == 1)
}

@Test func countingStoreEmptyMergeIsNoOp() {
    let store = CountingTagOpenFormCounterStore()
    let fire = TagOpenFormFire(tagName: "if", form: .parenCall)
    store.merge([fire: 4])
    store.merge([:])
    #expect(store.snapshot()[fire] == 4)
}

@Test func countingStoreDistinguishesSameFormAcrossDifferentTags() {
    // The real question fire-counts answer is per-TAG, not per-form
    // globally — a colon-call sighting on "loop" must never be conflated
    // with one on "if".
    let store = CountingTagOpenFormCounterStore()
    store.merge([TagOpenFormFire(tagName: "if", form: .colonCall): 1])
    store.merge([TagOpenFormFire(tagName: "loop", form: .colonCall): 1])
    let snapshot = store.snapshot()
    #expect(snapshot.count == 2)
}

@Test func noOpStoreIsInertRegardlessOfWhatIsMerged() {
    let store = NoOpTagOpenFormCounterStore()
    store.merge([TagOpenFormFire(tagName: "if", form: .parenCall): 99])
    #expect(store.snapshot().isEmpty)
}

// MARK: - Recognition-site accuracy (parse-level, no server/render needed)

@Test func ifParenCallIsRecordedAsParenCall() {
    let document = LassoParser().parse("<?lasso if(1 == 1) 'yes' /if ?>")
    #expect(document.openFormFires[TagOpenFormFire(tagName: "if", form: .parenCall)] == 1)
}

@Test func ifColonCallIsRecordedAsColonCall() {
    let document = LassoParser().parse("<?lasso if:(1 == 1); 'yes' /if; ?>")
    #expect(document.openFormFires[TagOpenFormFire(tagName: "if", form: .colonCall)] == 1)
}

@Test func ifBareConditionIsRecordedAsBareCondition() {
    let document = LassoParser().parse(
        """
        <?lasso
        if 1 == 1 {
            'yes'
        } else {
            'no'
        }
        ?>
        """
    )
    #expect(document.openFormFires[TagOpenFormFire(tagName: "if", form: .bareCondition)] == 1)
}

@Test func loopParenAndColonCallBothRecordUnderLoop() {
    let parenDocument = LassoParser().parse("<?lasso loop(3) 'x' /loop ?>")
    #expect(parenDocument.openFormFires[TagOpenFormFire(tagName: "loop", form: .parenCall)] == 1)

    let colonDocument = LassoParser().parse("<?lasso loop:(3); 'x' /loop; ?>")
    #expect(colonDocument.openFormFires[TagOpenFormFire(tagName: "loop", form: .colonCall)] == 1)
}

@Test func bareRecordsAndRowsAreRecordedAsBareIdentifier() {
    let recordsDocument = LassoParser().parse(
        """
        <?lasso
        records
            'row'
        /records
        ?>
        """
    )
    #expect(recordsDocument.openFormFires[TagOpenFormFire(tagName: "records", form: .bareIdentifier)] == 1)

    let rowsDocument = LassoParser().parse(
        """
        <?lasso
        rows
            'row'
        /rows
        ?>
        """
    )
    #expect(rowsDocument.openFormFires[TagOpenFormFire(tagName: "rows", form: .bareIdentifier)] == 1)
}

@Test func selectNeverRecordsAnyFireInScriptBody() {
    // select's openForms stays [] (TagCatalog.swift) — its real complexity
    // is branch-lowering in BlockBuilder, not a TagOpenForm concern — and
    // it never gained the Phase 4 bareOpenScopes widening while/protect did
    // (select's bare form was never real corpus syntax). Must never appear
    // in the fire table at all, not even as a zero.
    let selectDocument = LassoParser().parse("<?lasso select(1) case(1) 'one' /select ?>")
    #expect(selectDocument.openFormFires.keys.contains { $0.tagName == "select" } == false)
}

@Test func whileBareColonCallIsRecordedAsBareColonCall() {
    // Phase 4: while's real, paren-less colon-call form
    // (components/inSite/urlencode.inc's `while: #url_string >> '++';`)
    // now has a real TagOpenForm case and reaches emitStatement's bare-open
    // cascade — see the paired behavioral test below proving this also
    // fixed the actual block-pairing bug, not just the fire-count.
    let document = LassoParser().parse(
        """
        <?lasso
        while: #x >> 0;
            #x -= 1
        /while;
        ?>
        """
    )
    #expect(document.openFormFires[TagOpenFormFire(tagName: "while", form: .bareColonCall)] == 1)
}

@Test func protectBareFormIsRecordedAsBareIdentifier() {
    // Phase 4: protect's real bare zero-arg form (_botscript.lasso's bare
    // `protect ... /protect`) now has bareOpenScopes including .scriptBody,
    // reaching emitStatement's bare-open cascade as .bareIdentifier — the
    // same shape records/rows already had.
    let document = LassoParser().parse(
        """
        <?lasso
        protect
            'body'
        /protect
        ?>
        """
    )
    #expect(document.openFormFires[TagOpenFormFire(tagName: "protect", form: .bareIdentifier)] == 1)
}

// MARK: - Phase 4 regression: iterate:/while:/protect script-mode block-pairing bug

@Test func iterateBareColonCallNowLoopsOncePerElementInsteadOfRunningFlatOnce() async throws {
    // Before Phase 4, `iterate`'s bareOpenScopes lacked `.scriptBody`, so
    // `parseBlockOpening` (which requires `(` immediately after an optional
    // colon) fell through, and `emitStatement`'s bare-open cascade didn't
    // recognize `iterate` either — the whole `iterate: vars, local('i');`
    // statement became a meaningless flat `.code(...)` expression instead
    // of a real `.tag(..., closing: false, ...)` opener, so `BlockBuilder`
    // could never pair it with its `/iterate;` closer. Real corpus:
    // components/inSite/tables.inc's `iterate: vars, local:'i';`.
    // Reads `#out` back via bracket-mode syntax after the script block
    // closes, rather than relying on a bare script-mode expression
    // statement's own echo behavior, to isolate this test to exactly the
    // opener-pairing fix under test.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        """
        <?lasso
        local('out' = '')
        iterate: array('a', 'b', 'c'), local('i');
            #out += #i
        /iterate;
        ?>[#out]
        """,
        context: &context
    )
    #expect(output.trimmingCharacters(in: .whitespacesAndNewlines) == "abc")
}

@Test func whileBareColonCallNowLoopsUntilConditionFalseInsteadOfRunningOnce() async throws {
    // Same bug class as iterate above. Real corpus:
    // components/inSite/urlencode.inc's `while: #url_string >> '++';`.
    var context = LassoContext()
    let output = try await LassoRenderer().render(
        """
        <?lasso
        local('x' = 0)
        while: #x < 3;
            #x += 1
        /while;
        ?>[#x]
        """,
        context: &context
    )
    #expect(output.trimmingCharacters(in: .whitespacesAndNewlines) == "3")
}

@Test func protectBareFormNowActuallyCatchesErrorsInsteadOfLettingThemPropagate() async throws {
    // Same bug class as iterate/while above, but for protect's bare
    // zero-arg form. Real corpus: _botscript.lasso's bare
    // `protect ... /protect` (called from bot-blocking logic) — before
    // Phase 4 this wasn't pairing at all in script mode, so its body's
    // errors weren't actually being caught. Same synthetic
    // LassoRecoverableError setup as the existing bracket-mode
    // `protectCatchesRecoverableErrorAndSetsCurrentError` test, just
    // opened with the bare script-mode form instead of `[protect]`.
    // Uses `local('log')` accumulation plus a bracket-mode readback after
    // the script block closes, rather than relying on bare script-mode
    // expression-statement echo behavior, to isolate this test to exactly
    // the opener-pairing fix under test.
    var natives = LassoNativeRegistry()
    natives.register("fail_with_db_error") { _, _ in
        throw LassoRecoverableError(LassoErrorState(code: 42, message: "Add failed", kind: "add"))
    }
    var context = LassoContext(natives: natives)
    let output = try await LassoRenderer().render(
        """
        before-<?lasso
        local('log' = '')
        protect
            #log += 'during-'
            fail_with_db_error
            #log += 'unreached'
        /protect
        ?>[#log]after-[error_currenterror]-[error_currenterror(-errorcode)]
        """,
        context: &context
    )
    #expect(output == "before-during-after-Add failed-42")
}

@Test func inlineColonWithParensRecordsAnUnattestedColonCallSighting() {
    // The broader-gate design decision (Tim, 2026-07-16): record whenever a
    // tag has ANY documented open form at all, not gated on the specific
    // form matched — so a real `inline:(...)` (colon immediately followed
    // by parens) surfaces as a genuine sighting even though TagCatalog only
    // documents `inline` as `.parenCall`. This exact shape is a real,
    // already-tested regression guard elsewhere
    // (`inlineColonWithParensStillWorksAlongsideTheBareColonCallFix`) —
    // reusing it here as the canonical "unattested form still gets
    // counted" case, which is the whole point of the broader gate: knowing
    // about forms real traffic uses that the catalog doesn't yet document.
    let document = LassoParser().parse(
        """
        <?LassoScript
        inline:(-database='catalog_mysql', -table='skus', -sql='SELECT 1;');
            action_statement;
        /inline;
        ?>
        """
    )
    #expect(document.openFormFires[TagOpenFormFire(tagName: "inline", form: .colonCall)] == 1)
}

@Test func inlineBareColonCallWithNoParensRecordsBareColonCall() {
    // Phase 4 closed the gap Phase 3 left open (TagCatalog.swift's Phase 4
    // note): inline's real bare (paren-less) colon-call form now has a
    // real TagOpenForm case (.bareColonCall), and emitStatement's bare-open
    // cascade records it for any tag reaching that arm, not just
    // records/rows by exact name.
    let document = LassoParser().parse(
        """
        <?lasso
        inline:
            -database='catalog_mysql',
            -table='skus',
            -sql='SELECT 1;';
            action_statement;
        /inline;
        ?>
        """
    )
    #expect(document.openFormFires[TagOpenFormFire(tagName: "inline", form: .bareColonCall)] == 1)
}

// MARK: - Nested fold-up: define bodies, type methods, all four LassoParser
// bracket branches

@Test func defineBodyFoldsItsNestedIfFireUpToTheTopLevelDocument() {
    let document = LassoParser().parse(
        """
        <?lasso
        define classify(x::Integer) => {
            if(#x == 1) => {
                return 'one'
            }
            return 'other'
        }
        ?>
        """
    )
    #expect(document.openFormFires[TagOpenFormFire(tagName: "if", form: .parenCall)] == 1)
}

@Test func typeMethodBodyFoldsItsNestedIfFireUpToTheTopLevelDocument() {
    let document = LassoParser().parse(
        """
        <?lasso
        define Classifier => type {
            public classify(x::Integer) => {
                if(#x == 1) => {
                    return 'one'
                }
                return 'other'
            }
        }
        ?>
        """
    )
    #expect(document.openFormFires[TagOpenFormFire(tagName: "if", form: .parenCall)] == 1)
}

@Test func bracketSpanOpeningWithDefineFoldsItsNestedIfFire() {
    // LassoParser.swift's `bodyOpensWithDefine` branch — a whole
    // `define ... => { ... }` wrapped in one `[ ... ]` span (the
    // `[//lasso ... define ... ]` startup-library idiom).
    let document = LassoParser().parse(
        "[//lasso\ndefine classify(x::Integer) => { if(#x == 1) => { return 'one' } return 'other' }\n]"
    )
    #expect(document.openFormFires[TagOpenFormFire(tagName: "if", form: .parenCall)] == 1)
}

@Test func bracketSpanOpeningWithLegacyDefinitionFoldsItsNestedIfFire() {
    // LassoParser.swift's `bodyOpensWithLegacyDefinition` branch — a whole
    // legacy `define_tag:`/statement-list body wrapped in one `[ ... ]`
    // span.
    let document = LassoParser().parse(
        """
        [
        Define_Tag: 'classify';
            if:(1 == 1);
                'yes';
            /if;
        /Define_Tag;
        ]
        """
    )
    #expect(document.openFormFires[TagOpenFormFire(tagName: "if", form: .colonCall)] == 1)
}

@Test func bracketSpanEmbeddingAWholeBlockTagStatementFoldsItsNestedIfFire() {
    // LassoParser.swift's `expressions.count > 1` branch — a whole
    // block-tag statement (condition, body, else, closing tag) embedded in
    // ONE square-bracket span, real corpus's dominant single-bracket idiom.
    let document = LassoParser().parse("[if(1 == 1) 'yes' else 'no' /if]")
    #expect(document.openFormFires[TagOpenFormFire(tagName: "if", form: .parenCall)] == 1)
}

// MARK: - Per-request accumulation through includes and libraries

@Test func includeFireCountsAccumulateIntoTheRequestContext() async throws {
    struct IncludeLoader: LassoIncludeLoader {
        func loadInclude(path: String, from includingPath: String?) throws -> String {
            "<?lasso if:(1 == 1); 'included' /if; ?>"
        }
    }
    var context = LassoContext(includeLoader: IncludeLoader())
    _ = try await LassoRenderer().render("[include('/legacy.inc')]", context: &context)
    #expect(context.openFormFires[TagOpenFormFire(tagName: "if", form: .colonCall)] == 1)
}

@Test func libraryFireCountsAccumulateIntoTheRequestContextDespiteDiscardedOutput() async throws {
    // performLibrary discards the library's own text output by design
    // (library bodies run for side effects only) — this must not also
    // discard its fire counts, since library files are exactly where real
    // corpus legacy syntax concentrates (startup components).
    struct LibraryLoader: LassoIncludeLoader {
        func loadInclude(path: String, from includingPath: String?) throws -> String {
            "<?lasso if:(1 == 1); 'library side effect, discarded' /if; ?>"
        }
    }
    var context = LassoContext(includeLoader: LibraryLoader())
    _ = try await LassoRenderer().render("<?lasso library('/legacy.lasso') ?>", context: &context)
    #expect(context.openFormFires[TagOpenFormFire(tagName: "if", form: .colonCall)] == 1)
}

@Test func topLevelDocumentFireCountsReachContextEvenWithNoIncludesOrLibraries() async throws {
    var context = LassoContext()
    _ = try await LassoRenderer().render("<?lasso if:(1 == 1); 'yes' /if; ?>", context: &context)
    #expect(context.openFormFires[TagOpenFormFire(tagName: "if", form: .colonCall)] == 1)
}
