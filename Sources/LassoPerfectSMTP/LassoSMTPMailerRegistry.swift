//
//  LassoSMTPMailerRegistry.swift
//  LassoPerfectSMTP
//
//  Server-lifetime, shared `SMTPMailer` per named relay — see
//  Documentation/lasso-perfect-smtp-integration-plan.md §4.6. Built once
//  at server startup from the resolved `smtp` config block, so
//  `SMTPConnectionPool`'s pooling/circuit-breaking machinery is actually
//  realized across many `email_send` calls in one process, rather than
//  built fresh (and unpooled) per call. NOT a precedent-following mirror
//  of `FileMakerConnectionRegistry` — that type holds no live
//  connection/pool at all (a pure alias->host resolution table for the
//  admin console's live "switch datasource" feature); this type's
//  justification stands on SMTP being a genuinely stateful protocol
//  session Perfect-SMTP already built explicit pooling machinery for.
//
//  An `actor` (per the plan's explicit design, §4.6) even though its
//  `mailers` map is built once in `init` and never mutated afterward —
//  actor isolation is what makes this type's usage from many concurrent
//  request-handling tasks safe without the caller needing to reason about
//  it, and leaves room for a future live-relay-swap feature (§4.6's
//  "config-swap concurrency" note — explicitly NOT implemented here) to
//  add real mutable state later without a structural rewrite.
//

import Foundation
import LassoParser
import NIOCore
import PerfectSMTP

/// One named relay's resolved connection settings — host/port/auth/TLS
/// mode, everything `RelayConfig` needs. Deliberately a separate type from
/// `SMTPRelayFileConfig`/`SMTPRelaySettings` in `LassoPerfectServer`'s
/// `main.swift` (this target has no dependency on that executable target,
/// nor should it): the composition root (`main.swift`) is responsible for
/// translating its own JSON-config-shaped types into this one.
public struct LassoSMTPRelayDescriptor: Sendable {
    public let host: String
    public let port: Int
    public let user: String?
    public let password: String?
    public let tls: TLSMode

    public init(host: String, port: Int, user: String? = nil, password: String? = nil, tls: TLSMode) {
        self.host = host
        self.port = port
        self.user = user
        self.password = password
        self.tls = tls
    }

    var auth: RelayConfig.Auth {
        guard let user, let password, user.isEmpty == false else { return .none }
        return .plain(username: user, password: password)
    }
}

/// Thrown by `mailer(named:)` when `-host` names a relay absent from the
/// configured `relays` map — see `LassoSMTPMessageBuilder`'s doc comment
/// for why this design never falls back to the default relay or attempts
/// to dial the literal name as a host.
public enum LassoSMTPRelayError: Error, Equatable, Sendable {
    case unknownRelay(String)
    /// Startup-time invariant violation — `defaultRelay` must always name
    /// a key present in `relays` by the time this registry is
    /// constructed (`ServerConfig.load()` already validates this; this
    /// case exists so a future caller building a registry by hand, e.g. in
    /// a test, gets a clear failure instead of a silent `nil` default).
    case unknownDefaultRelay(String)
}

public actor LassoSMTPMailerRegistry {
    private let mailers: [String: SMTPMailer]
    private let defaultRelayName: String

    /// - Parameters:
    ///   - relays: Every configured named relay — see
    ///     `LassoSMTPRelayDescriptor`. One `SMTPMailer`, over one
    ///     `RelayTransport`/`SMTPConnectionPool`, is built per entry here,
    ///     immediately, at construction time — not lazily on first use —
    ///     so a startup-time relay-config mistake (bad TLS mode, etc.)
    ///     fails fast alongside every other backend this server validates
    ///     eagerly, rather than surfacing on the first real `email_send`.
    ///   - defaultRelay: Must be a key present in `relays` — throws
    ///     `LassoSMTPRelayError.unknownDefaultRelay` otherwise.
    ///   - group: The `EventLoopGroup` every relay's connection pool runs
    ///     on — not owned by this registry, matching `RelayTransport`'s own
    ///     "caller owns the group's lifecycle" contract.
    public init(relays: [String: LassoSMTPRelayDescriptor], defaultRelay: String, group: any EventLoopGroup) throws {
        guard relays[defaultRelay] != nil else {
            throw LassoSMTPRelayError.unknownDefaultRelay(defaultRelay)
        }
        var built: [String: SMTPMailer] = [:]
        for (name, descriptor) in relays {
            let config = RelayConfig(
                host: descriptor.host,
                port: descriptor.port,
                tls: descriptor.tls,
                auth: descriptor.auth
            )
            built[name] = SMTPMailer(transport: RelayTransport(config: config, group: group))
        }
        self.mailers = built
        self.defaultRelayName = defaultRelay
    }

    /// Test-only initializer: takes already-constructed mailers directly
    /// (e.g. wrapping a fake `SMTPTransport`) instead of dialing real
    /// `RelayTransport`s, mirroring `RelayTransport`'s own test-seam
    /// initializer.
    init(mailers: [String: SMTPMailer], defaultRelay: String) throws {
        guard mailers[defaultRelay] != nil else {
            throw LassoSMTPRelayError.unknownDefaultRelay(defaultRelay)
        }
        self.mailers = mailers
        self.defaultRelayName = defaultRelay
    }

    /// Resolves a relay by name — `nil` (no `-host` given) resolves to the
    /// configured default relay. A non-nil `name` that doesn't match any
    /// configured relay throws rather than silently falling back to the
    /// default or attempting to dial `name` itself as a literal host (§5).
    public func mailer(named name: String?) throws -> (name: String, mailer: SMTPMailer) {
        let resolvedName = name ?? defaultRelayName
        guard let mailer = mailers[resolvedName] else {
            throw LassoSMTPRelayError.unknownRelay(resolvedName)
        }
        return (resolvedName, mailer)
    }

    public var defaultRelay: String { defaultRelayName }

    public var configuredRelayNames: Set<String> { Set(mailers.keys) }
}
