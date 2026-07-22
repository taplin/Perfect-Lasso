import Foundation

/// Real Lasso 9's `dsinfo` type — the connection-metadata/action carrier
/// passed between a `datasource()`/`ds()`-style caller and a datasource
/// connector tag (documented, from the connector-AUTHOR's side, only at
/// the LCAPI/C level — lassoguide.com/api/lcapi-reference.html's own
/// `datasource_action_t` enum names match this type's `action` field
/// values 1:1, e.g. `datasourceExecSQL` ↔ `lcapi_datasourceExecSQL`).
/// **The Lasso-facing `dsinfo` type itself (its field names/defaults) is
/// NOT documented anywhere in LassoGuide** — searched
/// lcapi-sources.html, lcapi-reference.html, and lcapi-types.html
/// directly, all confirmed to have zero mention of it. The field list
/// below is reverse-engineered from every real usage site across
/// zeroloop/ds's full source (Task #178) — `grep -oh
/// 'dsinfo->[a-zA-Z_]*' *.lasso | sort -u` — not inferred or guessed at
/// beyond that. Defaults follow the same reasoning: fields ds.lasso
/// always sets explicitly before reading (`databasename`, `hostname`,
/// etc.) default to the type's natural empty value; fields that gate
/// behavior when falsy (`connection` — `if(#dsinfo->connection)`)
/// default to a falsy value; fields with no confirmable semantics at all
/// (`hostsextra`, `prepared`, `refobj` — genuinely opaque, connector-
/// internal state) default to `.null` via `LassoDataMemberDefinition`'s
/// own no-default convention, same as any ordinary untyped data member.
///
/// `dsinfo` is registered as an ordinary `LassoTagRegistry`-resolved type
/// (NOT a `NativeTypes.swift` Swift-backed one) deliberately —
/// `Evaluator.assign`'s `.member` case explicitly rejects raw field
/// writes on native types (`nativeTypeFieldAssignmentNotSupported`), but
/// `ds.lasso` mutates `dsinfo` fields directly and extensively
/// (`#dsinfo->hostname = #host`, etc.) — exactly the write pattern only
/// `tagRegistry`-resolved types support.
///
/// **Deliberately NOT implemented yet**: `getset(n::integer)` (returns a
/// raw result set by index — meaningless until a real datasource
/// connector populates one; stubbed to always return `void`) and any
/// real behavior behind `action`/`connection`/`prepared`/`refobj` — this
/// type is purely a passive data carrier. The connector that actually
/// DOES something with it (a real, invocable `mysqlds` tag) and the
/// `lcapi_datasource*` action/operator/sort/type constants it reads from
/// `dsinfo->action` are separate, not-yet-started pieces — see memory
/// `lasso-ds-runtime-invocation-scope.md`.
enum LassoDsInfoType {
    /// `TypeBodyParser`'s own `data`-section grammar (`name[::type][=
    /// default]`) — reused directly rather than hand-building
    /// `LassoDataMemberDefinition`/`LassoMethodDefinition` values, so
    /// this stays exactly as auditable as any other Lasso-defined type
    /// in this codebase. One `data` keyword per field, DELIBERATELY not
    /// the comma-continued multi-field-per-`data`-block form
    /// (`data\n public a = 1,\n public b = 2`) — found, while building
    /// this, to silently drop every field's default value (confirmed via
    /// a minimal repro: the comma-continued form registered `a`/`b`/`c`
    /// but each read back `.null`, while the exact same three fields as
    /// separate `data public name = value` lines worked correctly). Real,
    /// separate, pre-existing `TypeBodyParser`/`readLineContinuingCommas`
    /// bug — flagged, not fixed (out of scope here; this file only
    /// needed a working way to declare 24 fields, which one-per-line
    /// already is).
    private static let typeBodySource = """
    data public action::integer = 0
    data public connection::integer = 0
    data public databasename::string = ''
    data public hostdatasource::string = ''
    data public hostid::integer = 0
    data public hostname::string = ''
    data public hostpassword::string = ''
    data public hostport::string = ''
    data public hostschema::string = ''
    data public hostsextra
    data public hosttableencoding::string = ''
    data public hostusername::string = ''
    data public inputcolumns::staticarray = staticarray
    data public keycolumns::staticarray = staticarray
    data public maxrows::integer = 0
    data public numsets::integer = 1
    data public prepared
    data public refobj
    data public returncolumns::staticarray = staticarray
    data public skiprows::integer = 0
    data public sortColumns::staticarray = staticarray
    data public statement::string = ''
    data public statementonly::boolean = false
    data public tablename::string = ''

    public makeinheritedcopy => {
        local(copy) = dsinfo
        #copy->action = .action
        #copy->connection = .connection
        #copy->databasename = .databasename
        #copy->hostdatasource = .hostdatasource
        #copy->hostid = .hostid
        #copy->hostname = .hostname
        #copy->hostpassword = .hostpassword
        #copy->hostport = .hostport
        #copy->hostschema = .hostschema
        #copy->hostsextra = .hostsextra
        #copy->hosttableencoding = .hosttableencoding
        #copy->hostusername = .hostusername
        #copy->inputcolumns = .inputcolumns
        #copy->keycolumns = .keycolumns
        #copy->maxrows = .maxrows
        #copy->numsets = .numsets
        #copy->prepared = .prepared
        #copy->refobj = .refobj
        #copy->returncolumns = .returncolumns
        #copy->skiprows = .skiprows
        #copy->sortColumns = .sortColumns
        #copy->statement = .statement
        #copy->statementonly = .statementonly
        #copy->tablename = .tablename
        return #copy
    }

    public getset(n::integer) => void
    """

    static func makeDefinition() -> LassoTypeDefinition {
        let placeholderRange = SourceRange(
            start: SourcePosition(offset: 0, line: 0, column: 0),
            end: SourcePosition(offset: 0, line: 0, column: 0)
        )
        var parser = TypeBodyParser(source: typeBodySource, typeName: "dsinfo", range: placeholderRange)
        return parser.parse()
    }
}
