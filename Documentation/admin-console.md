# Admin Console

A browser-based operations dashboard for `lasso-perfect-server`, built on
`PerfectAdminConsole` (a general-purpose library in the sibling `Perfect-NIO`
package) plus Lasso-specific glue in this repo. This is the stable reference
doc for using it — for the implementation narrative and design rationale,
see `lasso-perfect-server.md`'s "Admin Console — 2026-07-16" section, and
for the underlying library's full protocol/API reference, see
`Perfect-NIO/README.md`'s "Admin console" section.

## What it's for

A single page where you can, without SSH access or a restart:

- See whether the server is up, what port it's on, and how long it's been running.
- See every configured datasource (MySQL and FileMaker), test connectivity to each on demand, and — for FileMaker — **switch which physical server an alias points at, live**.
- Trigger a full crawl-report sweep of the site and watch it progress in real time.
- Tail recent log lines (datasource failures, admin actions) without shelling in.
- See request/error counts for real site traffic.
- **Restart the server** — including picking up an edited config file — with zero dropped connections, instead of a manual `kill` + relaunch.

## Quick start

1. **Enable it** — set these when starting `lasso-perfect-server`:

   ```
   LASSO_ADMIN_CONSOLE=1
   LASSO_ADMIN_PORT=8990                    # optional, this is the default
   LASSO_ADMIN_TOKEN_PATH=/path/to/token     # optional, defaults under NSTemporaryDirectory()
   ```

   It's off by default — a normal server start with no `LASSO_ADMIN_CONSOLE`
   set doesn't open the admin port at all.

2. **Get the token** — on startup, the server prints and writes a random
   bearer token to `LASSO_ADMIN_TOKEN_PATH` (`chmod 600`, owner-only):

   ```
   [AdminConsole] http://127.0.0.1:8990 — token: /tmp/lasso-perfect-server-admin.token
   ```

   Read it with `cat` (or open the file) — never echo it to a shared
   terminal/log, since it's a live credential for the duration of that
   server process.

3. **Open the dashboard** — navigate to `http://127.0.0.1:8990` in a
   browser. Paste the token into the field and click **Connect**. The token
   is kept in `sessionStorage` (cleared when the tab closes or the server
   returns a 401 — e.g. after a restart generates a new token), so you'll
   re-paste it after every server restart.

**The admin port is always bound to `127.0.0.1` only**, regardless of what
`LASSO_SERVER_PORT` binds to — it's not reachable from another machine
without an SSH tunnel or similar, by design.

## Web dashboard walkthrough

The dashboard auto-refreshes every 5 seconds (see "refresh in Ns" in the
log card's footer). Every card described below updates on that same cycle.

- **Server Status** — admin port, site server port, uptime, TLS state, ACME pending-challenge count.
- **TLS Domains** / **ACME Challenges** — inert for this server (it doesn't terminate TLS itself); shows "No TLS configured".
- **Routes** — the literal route list `LassoSiteServer.routes()` registers.
- **Metrics** — total requests/errors served by the *site* (not the admin console's own routes), active connection count, and the top 5 busiest routes by request count. Fed live from real traffic; resets on restart (in-memory only, not persisted).
- **Datasources** — a full-width table (Datasource / Active Connection / Actions), one row per configured MySQL or FileMaker alias:
  - **Test** — pings the datasource for real (a live MySQL connect, or `FileMakerServer.databaseNames()` for FileMaker) and shows latency in a toast. No credentials are ever shown in the UI — only alias/schema/driver.
  - **Switch + a config dropdown** — FileMaker aliases only, and only when more than one connection profile is known for that alias (see "Live FileMaker datasource switching" below). MySQL aliases have no switcher — there's no per-alias override concept for that backend.
- **Log Tail** — the most recent captured log lines (datasource failures, admin-triggered action results), newest at the bottom, auto-scrolling if you were already at the bottom.
- **Lasso Site** — site root, startup folder, render extensions, session driver, image proxy config if set.
- **Actions** — grouped by category (Maintenance, TLS, Data). Each action shows a description that can reflect **live state**, not just a static blurb — most notably **Run Crawl Report**, whose description becomes `"Running now — 340/1,989 pages, started 2m ago"` while a crawl is in flight, and `"Last run: 1,943 page(s), 1,897 clean, 46 failing, 892 excluded (finished 11:04 AM)"` once it finishes. A destructive action (marked `(!)`) asks for confirmation before running.

## Live FileMaker datasource switching

Each FileMaker alias can have more than one known **connection profile**:
the shared `filemaker` config block (profile id `primary`) plus one profile
per alias that has its own `host`/`port` override in the datasources config
file (see `lasso-perfect-server.md`'s Configuration section for
`filemakerHostOverrides`/per-alias `host`/`port` fields). The dashboard's
Datasources card lists every known profile for an alias in the dropdown,
with the currently-active one pre-selected; clicking **Switch** re-points
that alias at a different profile immediately — no config edit, no
restart — and runs a real connectivity probe before reporting success.

This is deliberately **not** a way to introduce a brand-new, unaudited
host at runtime: the set of reachable hosts is still a config-file
decision (readable only by the file owner). Switching only changes *which
already-known host* an alias currently resolves to.

## Crawl-report action

Triggers the same crawl the `LASSO_CRAWL_REPORT=1` CLI mode runs (recursively
discovers every renderable page under the site root, requests each over
real HTTP, and reports pass/fail), but from the dashboard instead of an
environment variable and a restart. Runs in the background — the action
returns immediately, and progress/results show up on the action's own chip
and in the Log Tail. A second crawl can't be started while one is already
running (the button is not disabled, but it returns a clear "already
running" toast).

**Known limitation** — the crawler discovers pages by walking the
filesystem under the site root, not by following real hyperlinks. It only
ever requests each on-disk template file bare (no query string, no
session state), so any page only reachable through a dynamically generated
link — a record-detail page keyed by `?id=123`, search results, anything
the site constructs at runtime — is invisible to it. **A clean crawl-report
run means "every statically discoverable page renders," not "the site
works."** Full writeup: `crawl-report-filtering-plan.md`'s "Known
limitation" section.

## Restart Server action

Spawns a fresh copy of the server process (inheriting the current
environment — so it re-reads any edited config file, including
`LASSO_DATASOURCE_CONFIG_PATH`) and hands off to it, with **zero requests
refused during the handoff**. This is also the answer to "do I need to
rebuild after editing the datasource config?" — you don't; a restart is
enough, and this action is the no-shell-access way to trigger one.

How it stays safe: the new process is never trusted until it prints
confirmation that it genuinely bound the site port and started serving.
Only then does the old process gracefully cancel its own accept loop (new
connections already have somewhere to go — the new process, which shares
the port via `SO_REUSEPORT` — while in-flight requests on the old process
finish naturally rather than being cut off) and exit. If the new process
never proves itself healthy within 10 seconds, or crashes on startup, the
**old process is left running completely untouched** — there's never a
window with zero processes serving the site.

Two things worth knowing before you click it:
- **Bearer token rotates.** A fresh random token is generated on every
  process start, so the dashboard will 401 and drop back to the
  token-entry screen once the handoff completes — re-paste the new token
  from `LASSO_ADMIN_TOKEN_PATH`.
- **Session state is lost under the default in-memory session driver.**
  The new process boots with an empty session store, so every logged-in
  visitor gets signed out. The action's own description calls this out
  when `LASSO_SESSION_DRIVER` is unset or `memory`. Use a persistent
  session driver if this matters for your site.

A second restart can't be started while one is already in progress — the
action returns a clear "already in progress" failure instead of racing two
spawns.

## CWP Session Janitor

An opt-in background poller that lists FileMaker Server Admin API clients
and force-disconnects stale/excess Custom Web Publishing (CWP) sessions.
Off by default (`LASSO_CWP_JANITOR_ENABLED=1` to enable). All the actual
selection/sweep logic lives in a separate, Lasso-independent package,
`Perfect-FileMaker-AdminAPI` (`CWPSessionSelector`/`CWPSessionJanitor`/
`CWPSessionJanitorTracker`) — `lasso-perfect-server` only supplies config
values and a logging sink. Status, config, and last-sweep summary show up
in the dashboard's "CWP Session Janitor" section; a manual "Run CWP Janitor
Now" action triggers an immediate sweep instead of waiting for the next
poll.

**Why this exists**: FileMaker Server's Web Publishing Engine opens a new
CWP session whenever a client's prior session isn't free yet (bursty or
concurrent load is the trigger, not request volume or pacing alone), and
some of those extra sessions don't clear via WPE's own undocumented
internal reaper (observed live: up to ~30 minutes). Live testing
(2026-07-17/18) also confirmed this FileMaker Server install is licensed
for a hard maximum of 200 concurrent connections — once that's exhausted,
*any* new login attempt gets rejected, not just from the account that
caused the buildup. The janitor exists to clear stuck sessions proactively
rather than waiting on FileMaker's own slow/unreliable recovery.

**Selection logic**: being over `LASSO_CWP_JANITOR_MAX_SESSIONS` is the
ONLY trigger for considering a disconnect at all — a session's age alone
is never sufficient reason to kill it, even if very old, as long as total
count is under the limit. Once over the limit, the oldest sessions in that
excess are candidates, further narrowed by
`LASSO_CWP_JANITOR_DURATION_THRESHOLD_SECONDS` (only ones ALSO older than
this get disconnected) and rate-limited by
`LASSO_CWP_JANITOR_MAX_DISCONNECTS_PER_SWEEP` (drains a large backlog over
several sweeps instead of all at once). Never disconnects below
`LASSO_CWP_JANITOR_MIN_FLOOR` surviving sessions.

**Known limitation**: there is no signal available (from FileMaker's Admin
API or otherwise) for "is this session actively serving a request right
now" — only connection age and count. Duration is used as a proxy for
"probably orphaned," calibrated against live observations (well-behaved
sessions self-clear within ~1-2 minutes normally; a single request even
under heavy contention topped out around 19 seconds), not a guarantee.

**Config** (env vars, or `adminAPI` block in the datasource JSON config
file for host/port/user/password — a separate FileMaker Server admin
account from the CWP `filemaker` credentials):

| Var | Default | Notes |
|---|---|---|
| `LASSO_CWP_JANITOR_ENABLED` | `false` | |
| `LASSO_CWP_JANITOR_DRY_RUN` | `true` | only an explicit `0`/`false`/`no` arms real disconnects |
| `LASSO_CWP_JANITOR_POLL_INTERVAL_SECONDS` | `60` | |
| `LASSO_CWP_JANITOR_DURATION_THRESHOLD_SECONDS` | `150` | `0`/unset disables the duration filter (over-limit alone selects) |
| `LASSO_CWP_JANITOR_MAX_SESSIONS` | disabled | the sole trigger — `0`/unset means the janitor never selects anything |
| `LASSO_CWP_JANITOR_MIN_FLOOR` | `5` | |
| `LASSO_CWP_JANITOR_MAX_DISCONNECTS_PER_SWEEP` | unlimited | |
| `LASSO_FM_ADMIN_HOST` / `_PORT` / `_USER` / `_PASSWORD` | — | falls back to the config file's `adminAPI` block |
| `LASSO_FM_ADMIN_TRUST_SELF_SIGNED_TLS` | `false` | explicit opt-in to accept FileMaker Server's default self-signed cert on a known dev/test host — never enable this against a server reachable over an untrusted network |

**Tuning status (as of 2026-07-18)**: confirmed working live end-to-end —
correctly disconnects only over-limit-and-old sessions, respects the
per-sweep cap, and goes idle once back under the limit. `maxSessions` still
needs a real production value: the original incident that motivated this
feature froze at only ~20 open sessions, well below anything reproduced in
testing (90-200), so `maxSessions` must be set below this site's actual
normal peak concurrent CWP traffic for a repeat of that incident to ever
cross the threshold — not yet determined.

## Security model

- Admin port bound to `127.0.0.1` only.
- Bearer-token auth on every `/api/*` route (`Authorization: Bearer <token>`); token file is `chmod 600`, regenerated fresh on every server start.
- CSRF protection on every mutating route (POST/DELETE): requires an `X-Admin-CSRF: 1` header, and rejects any request whose `Origin` header doesn't match `http://127.0.0.1:<adminPort>` — a browser can't be tricked into sending the custom header cross-origin without a CORS preflight, which the admin server doesn't allow.
- No credentials of any kind (MySQL password, FileMaker password) are ever returned by any API route or rendered in the UI.

## API reference

All routes require `Authorization: Bearer <token>`; mutating routes (POST/DELETE) additionally require `X-Admin-CSRF: 1`. Full request/response shapes and curl examples for the generic protocol (status, TLS, ACME, logs, routes, metrics) live in `Perfect-NIO/README.md`'s "Admin console" section — this table is a quick index plus the Lasso-specific bodies.

| Route | Method | Notes |
|---|---|---|
| `/` | GET | Dashboard HTML (no auth — loads the token-entry form) |
| `/api/status` | GET | Server summary + the "Lasso Site" section |
| `/api/routes` | GET | Literal route list |
| `/api/datasources` | GET | Every alias, sanitized, with `configs` (FileMaker profiles) |
| `/api/datasources/test` | POST | Body `{"name": "<alias>"}` |
| `/api/datasources/switch` | POST | Body `{"name": "<alias>", "config": "<profile id>"}` |
| `/api/actions` | GET | Built-in + Lasso-specific actions, descriptions reflect live state |
| `/api/actions` | POST | Body `{"action": "crawl-report"}` (or `restart-server`, `clear-logs`, `reload-tls`) |
| `/api/logs` | GET | `?count=N`, default 100 |
| `/api/logs` | DELETE | Clears the ring buffer |
| `/api/metrics` | GET | Request/error counts, top routes |
| `/api/tls`, `/api/acme`, `/api/tls/reload`, `/api/tls/domain` | — | Present but inert — this server doesn't terminate TLS |

## Implementation reference

- `Sources/LassoPerfectServer/AdminConsoleIntegration.swift` — `LassoAdminDelegate`, the `AdminConsoleDelegate` conformance.
- `Sources/LassoPerfectServer/FileMakerConnectionRegistry.swift` — live per-alias FileMaker host resolution.
- `Sources/LassoPerfectServer/CrawlRunTracker.swift` — crawl-report live status tracking.
- `Sources/LassoPerfectServer/RestartCoordinator.swift` / `RestartReadiness.swift` — the restart action's concurrency guard and spawn/health-detection logic.
- `Sources/LassoPerfectServer/main.swift` — `siteServerTask`, the cancellable handle the restart action hands off through.
- `Perfect-NIO/Sources/PerfectNIO/Server.swift` — `alwaysReusePort`, the `SO_REUSEPORT` primitive the whole restart mechanism depends on.
- `Perfect-NIO/Sources/PerfectAdminConsole/` — the general-purpose library (routes, auth, CSRF, the dashboard HTML/JS itself).
