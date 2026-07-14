# Async MySQL Client Research (Phase 3 Findings)

Date: 2026-07-14

Research report only — no code changes proposed here. Context: Phase 1
(async render pipeline) and Phase 2 (thread-pool offload of blocking
MySQL calls) are in flight separately. This document answers: is there
a real path to a *genuinely*-async MySQL client — one that suspends
instead of parking an OS thread — and is it worth pursuing?

## Context

`PerfectCRUDLassoExecutor` (`Sources/LassoPerfectCRUD/PerfectCRUDLassoExecutor.swift`)
funnels all Lasso `[inline]` database actions through three synchronous
handler closures (`QueryHandler`, `MutationHandler`, `RawSQLHandler`).
`Sources/LassoPerfectServer/main.swift` (~line 385) implements those
handlers as `try makeDatabase(datasource).select(query)` / `.mutate(_:)` /
`.execute(_:)` — Perfect-CRUD's dynamic-query API backed by
`PerfectMySQL`, which blocks an OS thread for the full duration of every
connect + query. Notably, `makeDatabase` constructs a fresh
`MySQLDatabaseConfiguration` per request, and that initializer
(`Perfect-MySQL/Sources/PerfectMySQL/MySQLCRUD.swift:569`) calls
`connection.connect(...)` → `mysql_real_connect` synchronously — so
today every Lasso database action pays a blocking TCP connect +
handshake *and* a blocking query, with no pooling.

## Findings

### 1. What PerfectMySQL actually wraps

`/Users/timtaplin/Perfect-Resurrection/Perfect-MySQL/` is a thin Swift
wrapper over the C client library, exposed via an inline system-library
target (`Sources/mysqlclient/module.modulemap`, `pkgConfig: "mysqlclient"`,
brew provider `mysql-client` — `Package.swift:17-24`).

Every C call it makes is from the classic **synchronous** API. A full
symbol sweep (`grep -roE "mysql_[a-z_]+" Sources/PerfectMySQL/ | sort -u`)
shows ~50 distinct calls — `mysql_real_connect`, `mysql_real_query`,
`mysql_store_result`, `mysql_fetch_row`, and the whole
`mysql_stmt_*` prepared-statement family — and **zero** uses of any
nonblocking variant (`*_nonblocking`, `*_start`, `*_cont`).

Two details matter for any async plan:

- **The CRUD path is 100% prepared statements.** `MySQLCRUD.swift`'s
  `sqlExeDelegate(forSQL:)` (line ~592) always goes through `MySQLStmt`
  (`mysql_stmt_prepare` / `mysql_stmt_execute` / `mysql_stmt_fetch`,
  `MySQLStmt.swift`), never the text-protocol `mysql_real_query` path.
- **What actually links:** verified empirically —
  `otool -L ".build/out/Products/Debug/lasso-perfect-server"` →
  `/opt/homebrew/opt/mysql-client/lib/libmysqlclient.24.dylib`.
  That is **Oracle MySQL client 9.6.0** (Homebrew `mysql-client 9.6.0`;
  `LIBMYSQL_VERSION "9.6.0"` in
  `/opt/homebrew/opt/mysql-client/include/mysql/mysql_version.h`).
  Homebrew's `mariadb-connector-c 3.4.9` is *also* installed, but only
  `mysql-client` ships a `mysqlclient.pc`, so SwiftPM's
  `pkgConfig: "mysqlclient"` resolves to Oracle's library.

### 2. Does the C library offer a real non-blocking API?

Yes — but the two installed libraries offer **different, incompatible**
async surfaces, and the one we actually link is the weaker one.

**Oracle libmysqlclient 9.6.0 (what we link):** has the
`net_async_status`-based nonblocking API (added in MySQL 8.0.16).
Verified in `/opt/homebrew/opt/mysql-client/include/mysql/mysql.h`
(lines 494–825): `mysql_real_connect_nonblocking`,
`mysql_real_query_nonblocking`, `mysql_store_result_nonblocking`,
`mysql_fetch_row_nonblocking`, etc., and
`nm -gU libmysqlclient.dylib` confirms the symbols are exported.
**Critical gap:** there are *no* nonblocking prepared-statement calls —
`grep "stmt.*nonblocking" mysql.h` returns nothing. Since PerfectMySQL's
entire CRUD execution path is `mysql_stmt_*`, Oracle's nonblocking API
cannot be adopted without first rewriting the connector onto the text
protocol (losing typed parameter binding and inviting quoting/injection
concerns the stmt API avoids). Dead end in practice.

**MariaDB Connector/C 3.4.9 (installed but not linked):** has the full
`*_start`/`*_cont` nonblocking API, **including prepared statements** —
`mysql_stmt_prepare_start/cont`, `mysql_stmt_execute_start/cont`,
`mysql_stmt_fetch_start/cont` (verified in
`/opt/homebrew/opt/mariadb-connector-c/include/mariadb/mysql.h`
lines 660–777; `nm -gU lib/mariadb/libmariadb.dylib` confirms
`_mysql_stmt_execute_start` etc. are exported). The integration model
(per MariaDB's non-blocking library docs): each `_start` call returns a
`MYSQL_WAIT_READ|WRITE|EXCEPT` bitmask; the app watches the fd from
`mysql_get_socket()` (e.g. with a `DispatchSourceRead` or a NIO
`Channel`) and calls `_cont` when ready. The monorepo already contains
`/Users/timtaplin/Perfect-Resurrection/Perfect-MariaDB/` wrapping
`libmariadb` (`pkgConfig: "libmariadb"`), but its Swift code is the same
synchronous wrapper — zero `_start`/`_cont` usage today.

**Cost of the C-nonblocking route:** technically viable only via the
MariaDB connector, and it means hand-writing a per-connection async
state machine (every blocking call site in `MySQL.swift`/`MySQLStmt.swift`
becomes a start/poll/cont loop bridged to a continuation), plus a
connection pool, plus making the CRUD execution delegate async
(see §3). That is a substantial rewrite of Perfect-MySQL's internals to
end up with a hand-rolled, single-consumer version of what MySQLNIO
already is.

### 3. Existing NIO-native Swift clients, and what Perfect-CRUD could absorb

**MySQLNIO** (`vapor/mysql-nio`) is the credible candidate: a pure-Swift
MySQL wire-protocol implementation on SwiftNIO — no C library at all.
Verified current status: **v1.9.1 released 2026-02-18, MIT license,
Swift 6.0+, actively maintained by the Vapor core team** (last PR merged
days before this research). Auth support verified in
`Sources/MySQLNIO/MySQLConnectionHandler.swift`: `mysql_native_password`
and `caching_sha2_password`, including full authentication over non-TLS
connections via RSA public-key exchange — so it covers both legacy
(5.x-style accounts) and modern (8.x+ default) server auth.
**MySQLKit** (v4.10.1, same date) layers on SQLKit dialect support and
`EventLoopGroupConnectionPool` pooling. SwiftNIO is already in our
dependency graph via Perfect-NIO (`swift-nio 2.65+`), so no new
foundation is introduced.

**Could it back Perfect-CRUD?** Not through the existing connector
protocol. `SQLExeDelegate` / `DatabaseConfigurationProtocol`
(`Perfect-CRUD/Sources/PerfectCRUD/PerfectCRUD.swift:52-85`) are
synchronous pull-based (`hasNext() throws -> Bool`,
`next() -> KeyedDecodingContainer?`), and `Select` conforms to
`Sequence` (`Select.swift:10-65`) — a synchronous iterator cannot
`await`. Conforming an async client would force `async` through every
protocol requirement and turn `Select` into an `AsyncSequence`: a
breaking redesign of Perfect-CRUD's entire typed API, not an adapter.

**But the Lasso path doesn't need that.** Everything the interpreter
does funnels through three methods on `DynamicDatabaseProtocol`
(`Perfect-CRUD/Sources/PerfectCRUD/Dynamic.swift:167-170`) —
`select(_: DynamicQuery)`, `mutate(_: DynamicMutation)`,
`execute(_: DynamicSQL)` — all returning the `Sendable` value type
`DynamicResult`, and `PerfectCRUDLassoExecutor` receives them as
injected closures. Once Phase 1 makes the pipeline async, those handler
closures can become `async` and be implemented *directly* on
MySQLKit/MySQLNIO (compile `DynamicQuery` to SQL + bindings, run it on
a pooled connection, marshal rows into `DynamicResult`) — bypassing
Perfect-CRUD's connector layer for the MySQL datasource entirely. That
is an additive, few-hundred-line adapter, not a Perfect-CRUD redesign,
and it can coexist with the sync connector (smoke tools, session
driver) indefinitely.

### 4. Scale reality check

This server fronts a single resurrected legacy site (the scrubsSite
corpus), currently with connection-per-request and no pooling — the
blocking TCP connect per `[inline]` likely costs more than thread
occupancy does. At tens of concurrent requests, Phase 2's dedicated
thread pool wastes a few parked OS threads; that is noise on modern
hardware. Genuinely-async I/O pays off at hundreds-to-thousands of
concurrent in-flight queries, a regime this project has shown no sign
of approaching. Connection *pooling* would deliver more measurable win
than async-ness per se, and Phase 2 can provide it (a pool of persistent
connections married to the offload threads) without any new client.

## Recommendation

**Do not build or adopt a genuinely-async MySQL client now. Phase 2's
thread-pool offload is the right long-term answer at this project's
scale** — especially if it also introduces connection reuse, which is
the larger latency win hiding in the current per-request
`mysql_real_connect`.

Ranked disposition of the three possible paths:

1. **Phase 2 offload + pooled persistent connections (do this):**
   pragmatic, small, uses the existing battle-tested connector.
2. **MySQLNIO/MySQLKit behind the `DynamicQuery` handler seam (the
   escape hatch, only if measurement ever demands it):** actively
   maintained, MIT, Swift 6, pure Swift, auth-complete; adopt it as an
   async implementation of the three `LassoPerfectServer` handler
   closures, not as a Perfect-CRUD connector. Revisit only on observed
   cooperative-pool starvation under real load.
3. **C-library nonblocking APIs (don't):** Oracle's client — the one we
   actually link — has no nonblocking prepared-statement support, which
   PerfectMySQL's CRUD path depends on entirely; MariaDB's connector has
   the full API but would require hand-building an event-driven state
   machine, pooling, and an async CRUD delegate — reinventing MySQLNIO
   with a C dependency attached. Worst cost/benefit of the three.

### Verification commands used

```
otool -L ".build/out/Products/Debug/lasso-perfect-server" | grep -i mysql
  → /opt/homebrew/opt/mysql-client/lib/libmysqlclient.24.dylib
brew list --versions mysql-client mariadb-connector-c
  → mysql-client 9.6.0, mariadb-connector-c 3.4.9
grep -roE "mysql_[a-z_]+" Perfect-MySQL/Sources/PerfectMySQL/ | sort -u
  → sync API only; no *_start/*_cont/*_nonblocking
grep -n "nonblocking" /opt/homebrew/opt/mysql-client/include/mysql/mysql.h
  → query/fetch/connect covered; no mysql_stmt_* variants
grep -n "mysql_stmt.*_start" /opt/homebrew/opt/mariadb-connector-c/include/mariadb/mysql.h
  → full prepared-statement nonblocking API present
nm -gU <each dylib>  → confirmed exported symbols match headers
```

Ecosystem facts checked against github.com/vapor/mysql-nio and
github.com/vapor/mysql-kit (releases, license, Package.swift, and
`MySQLConnectionHandler.swift` auth-plugin implementation) as of
2026-07-14.
