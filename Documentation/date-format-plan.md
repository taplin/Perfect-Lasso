# Date_Format Plan

Last reviewed: July 12, 2026

## Implementation Status (2026-07-12)

Implemented. Grounded in both Lasso generations per established practice:
the local `References/Lasso/Lasso 8.5 Language Guide.pdf` (Chapter 29 "Date
and Time Operations," Table 1 "Date Substitution Tags," Table 2 "Date
Format Symbols") for the Lasso 8 tag-style contract, and the online Lasso 9
reference (lassoguide.com/operations/date-duration.html, fetched directly)
confirming Lasso 9 exposes the identical `%`-symbol table through a
`date->format(-format='...')` method rather than a free tag — same
dual-dialect shape as the Output/Encoding pass.

**Revised mid-plan per direct feedback**: the original design hand-computed
every symbol via `Calendar`/`DateComponents`, deliberately avoiding
`DateFormatter`. Asked directly whether the renderer could be based on
"the standard DateFormatter with its extended and more detailed
representation without breaking normal lasso behavior" — revised to
translate each Lasso `%`-symbol into an ICU pattern letter (`%Y`→`"yyyy"`,
`%B`→`"MMMM"`, etc.) and render through one reusable `DateFormatter`. This
is safe specifically because ICU's letter-repetition syntax shares no
spelling with Lasso's own `%`-prefixed mini-language — unlike reusing raw
C `strftime` directly, which *would* collide (`%h` is 12-hour-hour in
Lasso but abbreviated-month in C; `%w` is 1–7/Sunday-first in Lasso vs.
0–6/Sunday-first in C; `%Q`/`%q`/`%G` aren't C symbols at all).

Implemented: `Date`/`Date(...)` (no args → now; a date-ish string,
optionally with an explicit `-Format` to force parsing; or
`-Year`/`-Month`/`-Day`/`-Hour`/`-Minute`/`-Second` construction keywords);
`Date_Format` (required `-Format`, full documented `%`-symbol table, not
just the corpus-observed subset); `Date_LocalToGMT`/`Date_GMTToLocal`
(fixed-offset shift by the process's system time zone); `Server_Date`
(alias for bare `Date`); and the Lasso 9 `date->format(...)` method,
proven to match `Date_Format(date, ...)` byte-for-byte for the same input.

Real corpus usage (`grep`-counted, not assumed) confirmed scope: 13 of the
~20 documented `-Format` symbols actually appear (`%B %Y %Q %D %T %a %m %H
%M %S %r %w %d`); `Date_LocalToGMT`/`Server_Date` chain with `Date_Format`
in one real file. The remaining Chapter 29 tags (`Date_SetFormat`,
`Date_GetLocalTimeZone`, `Date_Minimum`/`Date_Maximum`, `Date_Msec`) have
zero corpus hits and are deferred.

**Representation**: a native `"date"` object (the same
`LassoNativeType`/`LassoObjectInstance` mechanism `web_request`/
`web_response` already use), storing six wall-clock `.integer` fields
(year/month/day/hour/minute/second) rather than a `Foundation.Date` — a
raw `Date` conflates "an absolute instant" with "a time zone" in a way
that doesn't match Lasso's own wall-clock-oriented model (the whole reason
`Date_LocalToGMT`/`Date_GMTToLocal` exist as separate tags). One real
consequence of this representation was worth calling out: a bare `Date`
identifier used with no call parens (`Date_Format(Date, -Format='%D')`,
the most common real corpus shape) resolves through the existing
"bare-identifier-checks-native-types-before-native-functions" precedent
(already established for `session`) to an *empty* `"date"` object with no
fields set — both `LassoDateParsing.parse`/`dateComponents(from:)` and the
`date->format` native method treat a missing/incomplete field set as "now"
rather than nil/empty-string, so this resolves correctly without a special
case in the evaluator.

Verified via 10 new tests (86/86 total, no regressions) and a live
real-corpus crawl (`LASSO_CRAWL_REPORT=1`): `unknownFunction("Date_Format")`
no longer appears anywhere in the failure report; clean pages held steady
at 1,690 of 1,989 (unchanged from the pre-Date_Format baseline) — the 20
previously-failing pages now progress further and stop at other,
already-documented, expected gaps (`Decode_Base64`, `Select`,
`Encrypt_HMAC`, `currency`), not a regression.

Deferred, zero corpus evidence: `Date_SetFormat`, `Date_GetLocalTimeZone`,
`Date_Minimum`/`Date_Maximum`, `Date_Msec`.

## Goal

Implement Lasso's `Date`/`Date_Format` and its documented GMT/local-time
siblings, grounded in both Lasso 8 tag-style and Lasso 9 method-style
documentation, prioritized by real corpus usage evidence, rendering
through `DateFormatter`'s ICU pattern language rather than hand-computed
symbol logic.

## Sources Reviewed

- `References/Lasso/Lasso 8.5 Language Guide.pdf`, Chapter 29 "Date and
  Time Operations" (Table 1: Date Substitution Tags; Table 2: Date Format
  Symbols).
- Online Lasso 9 reference: `lassoguide.com/operations/date-duration.html`
  (fetched directly) — confirms the identical `%`-symbol table and padding
  rules (`%_x` space-padded, `%-x` unpadded), exposed via a
  `date->format(-format='...')` method.
- Real corpus (site root path in the `lasso-real-corpus-paths` project
  memory, not hardcoded here) — `grep`-counted usage of `Date`/
  `Date_Format`/`Date_LocalToGMT`/`Server_Date` and every distinct
  `-Format` symbol actually used, before implementing.

## Documented Surface

### `Date` / `Date(...)`

Casts/constructs a date value: no args → now; a date string (optionally
with an explicit `-Format` to force parsing an ambiguous string); or
`-Year`/`-Month`/`-Day`/`-Hour`/`-Minute`/`-Second` to assemble one from
parts (`-DateGMT` — zero corpus evidence, not implemented).

### `Date_Format`

Reformats a date value or recognized date string via a required `-Format`
parameter, using the `%`-symbol table below. Recognized string shapes for
implicit (non-`-Format`-forced) parsing: US `M/d/yyyy[ H:mm:ss]`, ISO
`yyyy-MM-dd[ H:mm:ss]`, compact `yyyyMMddHHmmss`.

### `%`-symbol table (Lasso 8 Table 2 / Lasso 9 identical)

| Symbol | Meaning | ICU pattern used |
| --- | --- | --- |
| `%Y` | 4-digit year | `yyyy` |
| `%y` | 2-digit year | `yy` |
| `%m` | Month number | `MM` / `M` (unpadded) |
| `%B` | Full month name | `MMMM` |
| `%b` | Abbreviated month name | `MMM` |
| `%d` | Day of month | `dd` / `d` (unpadded) |
| `%A` | Full weekday name | `EEEE` |
| `%a` | Abbreviated weekday name | `EEE` |
| `%H` | Hour (24-hour) | `HH` / `H` (unpadded) |
| `%h` | Hour (12-hour) | `hh` / `h` (unpadded) |
| `%M` | Minute | `mm` / `m` (unpadded) |
| `%S` | Second | `ss` / `s` (unpadded) |
| `%p` | AM/PM | `a` |
| `%T` | `HH:mm:ss` | (composite) |
| `%r` | `hh:mm:ss a` | (composite) |
| `%D` | `MM/dd/yyyy` | (composite) |
| `%Q` | `yyyy-MM-dd` | (composite) |
| `%q` | `yyyyMMddHHmmss` | (composite) |
| `%z` | Numeric UTC offset | `Z` |
| `%Z` | Time zone abbreviation | `zzz` |
| `%w` | Weekday number, Sunday=1...Saturday=7 | direct `Calendar` computation (no ICU equivalent) |
| `%W` | Week of year | direct `Calendar` computation (lowest-confidence exact value — no precise corpus/doc example) |
| `%G` | GMT indicator | fixed `"GMT"` literal (lowest-confidence rendering — no precise corpus/doc example) |
| `%%` | Literal `%` | — |

`%_x` (space-pad) / `%-x` (no-pad) modifiers apply to any of the above:
ICU has no space-padding mode of its own, so padding is always applied
manually after requesting the unpadded rendering.

### `Date_LocalToGMT` / `Date_GMTToLocal`

Fixed-offset shift by `TimeZone.current.secondsFromGMT()` — this
interpreter has no separate "server time zone" config, so the process's
system time zone is the honest default (same posture as other
env-driven config elsewhere in this project).

### `Server_Date`

Alias for bare `Date` (now) — real semantics distinguish "server clock"
from "cast a value," but this interpreter only has one clock to read.

## Deferred

- `Date_SetFormat`, `Date_GetLocalTimeZone`, `Date_Minimum`/`Date_Maximum`,
  `Date_Msec` — documented in Chapter 29 but zero real corpus usage found.
- `-DateGMT` construction keyword on `Date` — zero corpus usage found.
