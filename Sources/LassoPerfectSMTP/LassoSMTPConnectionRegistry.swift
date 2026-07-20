//
//  LassoSMTPConnectionRegistry.swift
//  LassoPerfectSMTP
//
//  The live-connection store behind `email_smtp` (§4.8b) — the one
//  genuinely new piece of state Phase D needs. `email_compose`/`date`/
//  `bytes` are all value-shaped (their entire state fits inside a
//  `LassoObjectInstance`'s own `[String: LassoValue]` storage); `email_smtp`
//  needs a live `SMTPConnection` (a NIO channel wrapper) to survive between
//  independently-dispatched `->open`/`->command`/`->send`/`->close` calls
//  on the SAME Lasso object, and a live connection has no representable
//  `LassoValue` case at all — it was never going into that storage
//  regardless of which mutation mechanism was chosen (see
//  `NativeTypes.swift`'s `makeEmailSMTPType()` doc comment for the full
//  rationale this resolves).
//
//  Keyed by `ObjectIdentifier(receiver)`, where `receiver` is the exact
//  `LassoObjectInstance` every `email_smtp` native method receives as its
//  own first parameter — since `LassoObjectInstance` has real reference
//  identity (`TypeSystem.swift`'s `==` is `===`), two Lasso variables
//  holding the same object correctly share the same live connection. An
//  `actor` (not a plain class with a lock) because `LassoEmailProviderImpl`
//  is a plain `struct` reused across many concurrently-handled requests —
//  the same "shared, safely-concurrent state" justification
//  `LassoSMTPMailerRegistry`/`LassoMXLookupCache` already use.
//
//  ## Idle-timeout reaper
//
//  A page that errors out mid-sequence, or simply forgets `->close`,
//  would otherwise leak a live connection (and a registry entry) for the
//  rest of the process's life — `email_smtp` has no structural guarantee
//  `->close` is ever reached, unlike (say) a `defer`-scoped resource in
//  ordinary Swift code. `sweepIdleConnections(idleTimeout:)` closes and
//  evicts any entry unused for longer than `idleTimeout`; per this
//  project's own established "the periodic Task lives in the caller, the
//  resource type just exposes a sweep method" convention (see
//  `main.swift`'s CWP session janitor: `CWPSessionJanitor.sweep(...)` is a
//  plain async function, and `main.swift` itself owns the
//  `while !Task.isCancelled { ...; try? await Task.sleep(...) }` loop and
//  the cancellable `Task` handle) this actor does NOT start its own
//  background `Task` — `main.swift`'s `smtp` wiring block does, storing
//  the handle on `LassoSiteServer` so it can be cancelled (`deinit`)
//  rather than leaked. Five minutes (matching `SMTPConnection`'s own
//  default `replyTimeout`) is `sweepIdleConnections`'s documented default,
//  per §4.8b's own suggestion — a reasonable starting point, not a value
//  either doc source confirms.
//

import Foundation
import LassoParser
import PerfectSMTP

public actor LassoSMTPConnectionRegistry {
    private var connections: [ObjectIdentifier: SMTPConnection] = [:]
    /// Touched on every `insert`/`connection(for:)` lookup — "used," for
    /// this purpose, means "a `->open`/`->command`/`->send` call touched
    /// it," not merely "still present in the map." `remove(for:)`
    /// deliberately does not touch this (there's nothing left to track).
    private var lastUsed: [ObjectIdentifier: Date] = [:]

    public init() {}

    /// Called by `->open` on success. Overwrites any existing entry for
    /// this exact receiver without closing it first — real corpus usage
    /// calling `->open` twice on the same never-`->close`d object with no
    /// intervening close is not a case either doc source describes;
    /// silently leaking the first connection would be worse than this
    /// documented (if unconfirmed) last-write-wins behavior. Real usage
    /// (per the worked example) always pairs one `->open` with one
    /// `->close`.
    public func insert(_ connection: SMTPConnection, for receiver: LassoObjectInstance) {
        let key = ObjectIdentifier(receiver)
        connections[key] = connection
        lastUsed[key] = Date()
    }

    /// Called by `->command`/`->send`. Returns `nil` for a never-`->open`ed
    /// or already-`->close`d receiver — callers turn that into a clear,
    /// catchable "no open connection" error rather than crashing.
    public func connection(for receiver: LassoObjectInstance) -> SMTPConnection? {
        let key = ObjectIdentifier(receiver)
        guard let connection = connections[key] else { return nil }
        lastUsed[key] = Date()
        return connection
    }

    /// Called by `->close`. Returns the removed connection (if any) so the
    /// caller can close its channel — this actor does not close it itself,
    /// since closing is an async `Channel` operation this actor has no
    /// need to await internally (the one call site, `LassoEmailSMTPType.swift`'s
    /// `smtpClose`, awaits it directly). Returns `nil` — a safe no-op, not
    /// an error — for a never-`->open`ed or already-`->close`d receiver,
    /// per §4.8b's explicit "must not crash" requirement.
    @discardableResult
    public func remove(for receiver: LassoObjectInstance) -> SMTPConnection? {
        let key = ObjectIdentifier(receiver)
        lastUsed.removeValue(forKey: key)
        return connections.removeValue(forKey: key)
    }

    /// Closes and evicts every entry untouched for at least `idleTimeout`
    /// seconds. Returns the number of connections evicted (surfaced for
    /// logging/tests — `main.swift`'s reaper loop doesn't currently log
    /// this, but a test can assert on it directly rather than needing to
    /// inspect actor-private state). `idleTimeout` is a plain `TimeInterval`
    /// (seconds), not `Duration` — this keeps the comparison against
    /// `Date`/`Date.timeIntervalSinceNow` simple and lets tests inject a
    /// short (sub-second) timeout without a `Duration`-to-`TimeInterval`
    /// conversion.
    @discardableResult
    public func sweepIdleConnections(idleTimeout: TimeInterval = 300) async -> Int {
        let now = Date()
        let staleKeys = lastUsed
            .filter { now.timeIntervalSince($0.value) >= idleTimeout }
            .map(\.key)
        for key in staleKeys {
            lastUsed.removeValue(forKey: key)
            guard let connection = connections.removeValue(forKey: key) else { continue }
            try? await connection.channel.close()
        }
        return staleKeys.count
    }

    /// Test/introspection-only: how many connections this registry
    /// currently holds open — used by the idle-reaper regression test to
    /// confirm an eviction actually happened without reaching into
    /// otherwise-private state.
    public var openConnectionCount: Int {
        connections.count
    }
}
