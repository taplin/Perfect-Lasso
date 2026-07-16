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

@Test func whileProtectSelectNeverRecordAnyFire() {
    // openForms is [] for all three (TagCatalog.swift) — the recognition
    // gate at parseBlockOpening is "openForms non-empty," so these must
    // never appear in the fire table at all, not even as a zero.
    let whileDocument = LassoParser().parse("<?lasso while: #x >> 0; #x -= 1 /while; ?>")
    #expect(whileDocument.openFormFires.keys.contains { $0.tagName == "while" } == false)

    let protectDocument = LassoParser().parse("[protect]during[/protect]")
    #expect(protectDocument.openFormFires.keys.contains { $0.tagName == "protect" } == false)

    let selectDocument = LassoParser().parse("<?lasso select(1) case(1) 'one' /select ?>")
    #expect(selectDocument.openFormFires.keys.contains { $0.tagName == "select" } == false)
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

@Test func inlineBareColonCallWithNoParensNeverRecordsAnyFire() {
    // The documented gap (TagCatalog.swift's Phase 3 note): inline's real
    // bare (paren-less) colon-call form has no TagOpenForm case to record
    // against, and emitStatement's bare-open cascade only records for
    // records/rows by exact name. Confirms this phase does not silently
    // force-fit a count here.
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
    #expect(document.openFormFires.keys.contains { $0.tagName == "inline" } == false)
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
