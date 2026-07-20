//
//  LassoEmailSMTPEndToEndTests.swift
//  LassoPerfectSMTPTests
//
//  `email_smtp` (Phase D, §4.8b) — renders real `[email_smtp]`/
//  `->open`/`->command`/`->send`/`->close` calls through a `LassoContext`
//  wired with a real `LassoEmailProviderImpl`, against a minimal
//  real-socket fake SMTP server (mirroring Perfect-SMTP's own
//  `STARTTLSRealSocketTests.swift`/`DirectMXRealSocketTests.swift`
//  pattern — a `ServerBootstrap` + hand-rolled line handler on a real
//  loopback listener, not `EmbeddedChannel` — since `email_smtp` dials
//  directly via `SMTPBootstrap.connect`, bypassing `SMTPMailer`/
//  `SMTPTransport` entirely, so the fake-`SMTPTransport` machinery
//  `LassoPerfectSMTPEndToEndTests.swift`/`LassoEmailComposeEndToEndTests.swift`
//  use can't exercise this code path at all).
//
//  Confirms:
//  - bare `email_smtp` (no parens) constructs an empty object with no live
//    connection — `->close` on it is a safe no-op, not a crash;
//  - the with-args constructor form stores `-host`/`-port`/`-username`/
//    `-password` as defaults `->open()` (with no arguments of its own)
//    actually dials with;
//  - `->open` performs the full connect + EHLO + AUTH handshake and
//    `->send` delivers a message end to end;
//  - `->open` fails clearly (a `[protect]`-catchable error, not a crash)
//    against an unreachable host and against a server that rejects AUTH;
//  - `->send` surfaces a real delivery failure (RCPT TO rejected) as a
//    thrown, catchable error;
//  - `->command` round-trips a raw line against `-expect`/`-read`;
//  - `->close` removes the registry entry (proven by a subsequent
//    `->send` throwing "no open connection") and is safe to call twice;
//  - two Lasso variables referencing the SAME `email_smtp` object share
//    the same live connection (`local(alias) = $smtp` then calling
//    `->command` through `$alias` reaches the connection `$smtp->open`ed)
//    — the reference-semantics claim, proven rather than just asserted;
//  - the idle-timeout reaper actually closes and evicts a stale entry
//    (exercised directly against `LassoSMTPConnectionRegistry`/
//    `LassoEmailProviderImpl.smtpOpen`, with a short injected timeout
//    rather than waiting 5 real minutes).
//

import Foundation

import NIOCore
import NIOPosix
import Testing
@testable import LassoParser
@testable import LassoPerfectSMTP
import PerfectSMTP

struct LassoEmailSMTPEndToEndTests {
    private static func makeContext(
        siteRoot: URL = FileManager.default.temporaryDirectory,
        connectionRegistry: LassoSMTPConnectionRegistry = LassoSMTPConnectionRegistry(),
        group: any EventLoopGroup = MultiThreadedEventLoopGroup.singleton,
        // Every test below exercises real `->open` behavior, so the gate
        // (milestone review, BLOCKING #2 — off by `false` in real
        // deployments) is explicitly enabled here; `emailSMTPGateTests`
        // below cover the default-`false`/off behavior specifically.
        allowEmailSMTP: Bool = true
    ) throws -> LassoContext {
        struct UnusedTransport: SMTPTransport {
            func send(_ envelope: SMTPEnvelope, _ message: SignedMessage) async throws -> [DeliveryResult] {
                Issue.record("email_smtp must never dial through the named-relay SMTPMailer/SMTPTransport path")
                return []
            }
        }
        let registry = try LassoSMTPMailerRegistry(
            mailers: ["primary": SMTPMailer(transport: UnusedTransport())],
            defaultRelay: "primary"
        )
        return LassoContext(emailProvider: LassoEmailProviderImpl(
            registry: registry,
            siteRoot: siteRoot,
            connectionRegistry: connectionRegistry,
            group: group,
            allowEmailSMTP: allowEmailSMTP
        ))
    }

    // MARK: - Bare construction

    @Test func bareConstructionHasNoLiveConnectionAndCloseIsASafeNoOp() async throws {
        var context = try Self.makeContext()

        let output = try await LassoRenderer().render(
            "[local(smtp) = email_smtp][#smtp->close]after",
            context: &context
        )
        #expect(output == "after")
    }

    @Test func closeOnANeverOpenedObjectDoesNotThrow() async throws {
        var context = try Self.makeContext()

        // Two closes in a row on an object that was never opened at all —
        // both must be silent no-ops, never a crash or a thrown error.
        _ = try await LassoRenderer().render(
            "[local(smtp) = email_smtp][#smtp->close][#smtp->close]",
            context: &context
        )
    }

    // MARK: - Real handshake against a real socket

    @Test func openPerformsFullHandshakeAndSendDeliversSuccessfully() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let server = try await FakeSMTPServer.start(group: group, authBehavior: .succeed, rcptBehavior: .accept)
        var context = try Self.makeContext(group: group)

        let output = try await LassoRenderer().render(
            "[local(smtp) = email_smtp]" +
            "[#smtp->open(-host='127.0.0.1', -port=\(server.port), -username='user', -password='pass', -timeout=5)]" +
            "[#smtp->send(-from='sender@example.com', -recipients=array('rcpt@example.com'), -message='Subject: hi\\r\\n\\r\\nbody\\r\\n')]" +
            "[#smtp->close]done",
            context: &context
        )

        try await server.channel.close()
        try await group.shutdownGracefully()

        #expect(output == "done")
    }

    @Test func withArgsConstructorStoresDefaultsThatBareOpenUses() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let server = try await FakeSMTPServer.start(group: group, authBehavior: .succeed, rcptBehavior: .accept)
        var context = try Self.makeContext(group: group)

        // `->open()` is called with NO arguments of its own here — every
        // connection parameter must come from the constructor's stored
        // `_host`/`_port`/`_username`/`_password` defaults for this to
        // succeed at all against the real fake server.
        let output = try await LassoRenderer().render(
            "[local(smtp) = email_smtp(-host='127.0.0.1', -port=\(server.port), -username='user', -password='pass')]" +
            "[#smtp->open]" +
            "[#smtp->close]done",
            context: &context
        )

        try await server.channel.close()
        try await group.shutdownGracefully()

        #expect(output == "done")
    }

    @Test func openArgumentsOverrideConstructorDefaultsWhenBothAreGiven() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let server = try await FakeSMTPServer.start(group: group, authBehavior: .succeed, rcptBehavior: .accept)
        var context = try Self.makeContext(group: group)

        // The constructor is given a deliberately wrong port (1 — nothing
        // listens there); `->open`'s own `-port` argument must win, or
        // this hangs/fails to connect.
        let output = try await LassoRenderer().render(
            "[local(smtp) = email_smtp(-host='127.0.0.1', -port=1)]" +
            "[#smtp->open(-port=\(server.port), -timeout=5)]" +
            "[#smtp->close]done",
            context: &context
        )

        try await server.channel.close()
        try await group.shutdownGracefully()

        #expect(output == "done")
    }

    @Test func openFailsClearlyOnAnUnreachableHostRatherThanHangingOrCrashing() async throws {
        // A real loopback listener, bound then immediately closed — the
        // OS guarantees an immediate ECONNREFUSED for a subsequent connect
        // to the now-closed port, deterministically, with no timing
        // dependency (unlike a firewalled/black-holed address, which
        // would only fail once `-timeout` elapses).
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let bootstrap = ServerBootstrap(group: group)
            .childChannelInitializer { channel in channel.eventLoop.makeCompletedFuture { } }
        let channel = try await bootstrap.bind(host: "127.0.0.1", port: 0).get()
        guard let closedPort = channel.localAddress?.port else {
            Issue.record("could not bind a throwaway port")
            return
        }
        try await channel.close()

        var context = try Self.makeContext(group: group)

        let output = try await LassoRenderer().render(
            "[protect][local(smtp) = email_smtp][#smtp->open(-host='127.0.0.1', -port=\(closedPort), -timeout=5)][/protect]after-[error_currenterror]",
            context: &context
        )

        try await group.shutdownGracefully()

        #expect(output.hasPrefix("after-"))
        #expect(output.contains("email_smtp->open") || output.contains("connecting"))
    }

    @Test func openFailsClearlyOnBadAuthRatherThanCrashing() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let server = try await FakeSMTPServer.start(group: group, authBehavior: .fail, rcptBehavior: .accept)
        var context = try Self.makeContext(group: group)

        let output = try await LassoRenderer().render(
            "[protect][local(smtp) = email_smtp]" +
            "[#smtp->open(-host='127.0.0.1', -port=\(server.port), -username='user', -password='wrong', -timeout=5)]" +
            "[/protect]after-[error_currenterror]",
            context: &context
        )

        try await server.channel.close()
        try await group.shutdownGracefully()

        #expect(output.hasPrefix("after-"))
    }

    @Test func missingHostThrowsAClearErrorRatherThanCrashing() async throws {
        var context = try Self.makeContext()

        let output = try await LassoRenderer().render(
            "[protect][local(smtp) = email_smtp][#smtp->open][/protect]after-[error_currenterror]",
            context: &context
        )

        #expect(output.hasPrefix("after-"))
        #expect(output.contains("Requires a -host"))
    }

    @Test func sendSurfacesADeliveryFailureAsAThrownCatchableErrorNotACrash() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let server = try await FakeSMTPServer.start(group: group, authBehavior: .succeed, rcptBehavior: .reject)
        var context = try Self.makeContext(group: group)

        let output = try await LassoRenderer().render(
            "[local(smtp) = email_smtp]" +
            "[#smtp->open(-host='127.0.0.1', -port=\(server.port), -timeout=5)]" +
            "[protect][#smtp->send(-from='sender@example.com', -recipients=array('rcpt@example.com'), -message='Subject: hi\\r\\n\\r\\nbody\\r\\n')][/protect]after-[error_currenterror]" +
            "[#smtp->close]",
            context: &context
        )

        try await server.channel.close()
        try await group.shutdownGracefully()

        #expect(output.contains("after-"))
        #expect(output.contains("delivery failed"))
    }

    @Test func commandRoundTripsARawLineAgainstExpectAndRead() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let server = try await FakeSMTPServer.start(group: group, authBehavior: .succeed, rcptBehavior: .accept)
        var context = try Self.makeContext(group: group)

        let output = try await LassoRenderer().render(
            "[local(smtp) = email_smtp]" +
            "[#smtp->open(-host='127.0.0.1', -port=\(server.port), -timeout=5)]" +
            "[#smtp->command(-send='NOOP', -expect=250)]|" +
            "[#smtp->command(-send='NOOP', -read=true)]" +
            "[#smtp->close]",
            context: &context
        )

        try await server.channel.close()
        try await group.shutdownGracefully()

        let parts = output.components(separatedBy: "|")
        #expect(parts.count == 2)
        #expect(parts[0] == "true")
        #expect(parts[1].contains("2.0.0"))
    }

    @Test func closeRemovesTheRegistryEntrySoASubsequentSendThrowsNoOpenConnection() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let server = try await FakeSMTPServer.start(group: group, authBehavior: .succeed, rcptBehavior: .accept)
        var context = try Self.makeContext(group: group)

        let output = try await LassoRenderer().render(
            "[local(smtp) = email_smtp]" +
            "[#smtp->open(-host='127.0.0.1', -port=\(server.port), -timeout=5)]" +
            "[#smtp->close]" +
            "[protect][#smtp->send(-from='a@example.com', -recipients=array('b@example.com'), -message='x')][/protect]after-[error_currenterror]",
            context: &context
        )

        try await server.channel.close()
        try await group.shutdownGracefully()

        #expect(output.hasPrefix("after-"))
        #expect(output.contains("no open connection"))
    }

    // MARK: - Reference semantics: two variables, one live connection

    @Test func twoVariablesReferencingTheSameObjectShareTheSameLiveConnection() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let server = try await FakeSMTPServer.start(group: group, authBehavior: .succeed, rcptBehavior: .accept)
        var context = try Self.makeContext(group: group)

        // `#alias` never calls `->open` itself — if this succeeds, it can
        // only be because `local(alias) = #smtp` shares the exact same
        // underlying `LassoObjectInstance` (and therefore the exact same
        // `LassoSMTPConnectionRegistry` entry) `#smtp->open` populated.
        let output = try await LassoRenderer().render(
            "[local(smtp) = email_smtp]" +
            "[#smtp->open(-host='127.0.0.1', -port=\(server.port), -timeout=5)]" +
            "[local(alias) = #smtp]" +
            "[#alias->command(-send='NOOP', -expect=250)]" +
            "[#smtp->close]",
            context: &context
        )

        try await server.channel.close()
        try await group.shutdownGracefully()

        #expect(output == "true")
    }

    // MARK: - Idle-timeout reaper (§4.8b)

    @Test func idleTimeoutReaperClosesAndEvictsAStaleConnection() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let server = try await FakeSMTPServer.start(group: group, authBehavior: .succeed, rcptBehavior: .accept)
        let registry = LassoSMTPConnectionRegistry()
        let context = try Self.makeContext(connectionRegistry: registry, group: group)
        guard let emailProvider = context.emailProvider else {
            Issue.record("expected a configured emailProvider")
            return
        }

        _ = try await emailProvider.smtpOpen(
            LassoObjectInstance(typeName: "email_smtp"),
            [
                EvaluatedArgument(label: "host", value: .string("127.0.0.1")),
                EvaluatedArgument(label: "port", value: .integer(Int(server.port))),
                EvaluatedArgument(label: "timeout", value: .integer(5)),
            ],
            context: context
        )
        #expect(await registry.openConnectionCount == 1)

        // An injected, sub-second idle timeout rather than waiting 5 real
        // minutes — `sweepIdleConnections`'s own default is 300s, but the
        // parameter exists specifically so callers (this test included)
        // can override it.
        let evicted = await registry.sweepIdleConnections(idleTimeout: 0.05)
        try? await Task.sleep(for: .milliseconds(100))
        let evictedAfterWait = evicted > 0 ? evicted : await registry.sweepIdleConnections(idleTimeout: 0.05)

        try await server.channel.close()
        try await group.shutdownGracefully()

        #expect(evicted > 0 || evictedAfterWait > 0)
        #expect(await registry.openConnectionCount == 0)
    }

    // MARK: - Connection-hijack regression (milestone review, BLOCKING #1)

    /// Can't literally force an address-reuse collision in a test (ARC/the
    /// allocator give no reliable hook for that), so this proves the fix
    /// structurally instead: the abandoned object's registry entry
    /// survives ONLY because the registry retains its own `receiver`
    /// (proving the retain actually happens, not just compiles), and a
    /// completely separate, never-`->open`ed object never resolves to that
    /// live connection -- the exact "no accidental success" guarantee the
    /// review asked for.
    @Test func abandonedConnectionNeverLeaksToAnUnrelatedNeverOpenedObject() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let server = try await FakeSMTPServer.start(group: group, authBehavior: .succeed, rcptBehavior: .accept)
        let registry = LassoSMTPConnectionRegistry()
        let context = try Self.makeContext(connectionRegistry: registry, group: group)
        guard let emailProvider = context.emailProvider else {
            Issue.record("expected a configured emailProvider")
            return
        }

        // Mirrors the routine control-flow pattern the review flagged
        // (early scope exit / `[protect]`-caught error / loop-scoped
        // local): open a real, authenticated connection, then never
        // reference the receiver again -- this test itself holds no
        // reference to it once this block ends.
        _ = try await emailProvider.smtpOpen(
            LassoObjectInstance(typeName: "email_smtp"),
            [
                EvaluatedArgument(label: "host", value: .string("127.0.0.1")),
                EvaluatedArgument(label: "port", value: .integer(Int(server.port))),
                EvaluatedArgument(label: "timeout", value: .integer(5)),
            ],
            context: context
        )
        // The entry survives -- proving the registry itself retained the
        // receiver (pre-fix, nothing did, and this would be indistinguishable
        // from a leak either way, which is exactly why the fix needs the
        // next assertion too, not just this one).
        #expect(await registry.openConnectionCount == 1)

        // A brand-new, never-`->open`ed `LassoObjectInstance` must resolve
        // to `nil` -- never to the abandoned connection above. Pre-fix,
        // this couldn't be forced to collide in a test (no reliable
        // address-reuse hook), but the map's value type retaining `receiver`
        // makes the collision structurally impossible regardless: this
        // object and the abandoned one are simultaneously alive right here,
        // so they provably have distinct `ObjectIdentifier`s.
        let unrelated = LassoObjectInstance(typeName: "email_smtp")
        let resolved = await registry.connection(for: unrelated)
        #expect(resolved == nil)

        await #expect(throws: Error.self) {
            _ = try await emailProvider.smtpSend(
                unrelated,
                [
                    EvaluatedArgument(label: "from", value: .string("a@example.com")),
                    EvaluatedArgument(label: "recipients", value: .array([.string("b@example.com")])),
                    EvaluatedArgument(label: "message", value: .string("x")),
                ],
                context: context
            )
        }

        try await server.channel.close()
        try await group.shutdownGracefully()
    }

    // MARK: - Off-by-default operator gate (milestone review, BLOCKING #2)

    @Test func openThrowsAClearNotEnabledErrorWhenTheGateIsOff() async throws {
        var context = try Self.makeContext(allowEmailSMTP: false)

        let output = try await LassoRenderer().render(
            "[protect][local(smtp) = email_smtp][#smtp->open(-host='127.0.0.1', -port=25)][/protect]after-[error_currenterror]",
            context: &context
        )

        #expect(output.hasPrefix("after-"))
        #expect(output.contains("email_smtp is not enabled"))
    }

    @Test func openReachesTheRealDialAttemptWhenTheGateIsExplicitlyEnabled() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let server = try await FakeSMTPServer.start(group: group, authBehavior: .succeed, rcptBehavior: .accept)
        var context = try Self.makeContext(group: group, allowEmailSMTP: true)

        let output = try await LassoRenderer().render(
            "[local(smtp) = email_smtp]" +
            "[#smtp->open(-host='127.0.0.1', -port=\(server.port), -timeout=5)]" +
            "[#smtp->close]done",
            context: &context
        )

        try await server.channel.close()
        try await group.shutdownGracefully()

        #expect(output == "done")
    }
}

// MARK: - Fake SMTP server

/// A minimal, real-socket fake SMTP server, mirroring Perfect-SMTP's own
/// `STARTTLSRealSocketTests.swift`/`DirectMXRealSocketTests.swift`
/// established pattern (a `ServerBootstrap` + hand-rolled, LF-tolerant
/// line handler on a real loopback listener) — extended here with AUTH
/// PLAIN support and a scriptable RCPT TO outcome, since `email_smtp`'s
/// own tests need both.
private enum FakeSMTPServer {
    enum AuthBehavior { case succeed, fail }
    enum RCPTBehavior: Equatable { case accept, reject }

    struct Running {
        let channel: Channel
        let port: Int
    }

    static func start(
        group: any EventLoopGroup,
        authBehavior: AuthBehavior,
        rcptBehavior: RCPTBehavior
    ) async throws -> Running {
        let bootstrap = ServerBootstrap(group: group)
            .childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(
                        FakeSMTPServerHandler(authBehavior: authBehavior, rcptBehavior: rcptBehavior)
                    )
                }
            }
        let channel = try await bootstrap.bind(host: "127.0.0.1", port: 0).get()
        guard let port = channel.localAddress?.port else {
            throw FakeSMTPServerError.noLocalPort
        }
        return Running(channel: channel, port: port)
    }
}

private enum FakeSMTPServerError: Error { case noLocalPort }

private final class FakeSMTPServerHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private let authBehavior: FakeSMTPServer.AuthBehavior
    private let rcptBehavior: FakeSMTPServer.RCPTBehavior
    private var accumulated = ByteBuffer()
    private var inData = false

    init(authBehavior: FakeSMTPServer.AuthBehavior, rcptBehavior: FakeSMTPServer.RCPTBehavior) {
        self.authBehavior = authBehavior
        self.rcptBehavior = rcptBehavior
    }

    func channelActive(context: ChannelHandlerContext) {
        writeLine(context: context, "220 fake.example ESMTP")
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var incoming = Self.unwrapInboundIn(data)
        accumulated.writeBuffer(&incoming)
        if inData {
            drainDataPhaseIfTerminated(context: context)
            return
        }
        while let line = extractLine() {
            handle(line: line, context: context)
        }
    }

    private func extractLine() -> String? {
        guard let lfIndex = accumulated.readableBytesView.firstIndex(of: 0x0A) else { return nil }
        let length = lfIndex - accumulated.readerIndex
        guard let bytes = accumulated.readBytes(length: length) else { return nil }
        accumulated.moveReaderIndex(forwardBy: 1)
        var text = String(decoding: bytes, as: UTF8.self)
        if text.hasSuffix("\r") { text.removeLast() }
        return text
    }

    private func handle(line: String, context: ChannelHandlerContext) {
        let upper = line.uppercased()
        if upper.hasPrefix("EHLO") {
            writeLine(context: context, "250-fake.example Hello")
            writeLine(context: context, "250 AUTH PLAIN")
        } else if upper.hasPrefix("AUTH PLAIN") {
            switch authBehavior {
            case .succeed: writeLine(context: context, "235 2.7.0 Authentication successful")
            case .fail: writeLine(context: context, "535 5.7.8 Authentication failed")
            }
        } else if upper.hasPrefix("MAIL FROM") {
            writeLine(context: context, "250 2.1.0 OK")
        } else if upper.hasPrefix("RCPT TO") {
            switch rcptBehavior {
            case .accept: writeLine(context: context, "250 2.1.5 OK")
            case .reject: writeLine(context: context, "550 5.1.1 Mailbox unavailable")
            }
        } else if upper == "DATA" {
            if rcptBehavior == .reject {
                // No RCPT was ever accepted -- a real server (and
                // `SMTPConnection.sendMessage` itself) never sends DATA in
                // that case, so this branch shouldn't be reachable in that
                // scenario; kept only as a defensive no-op.
                return
            }
            writeLine(context: context, "354 Go ahead")
            inData = true
            drainDataPhaseIfTerminated(context: context)
        } else if upper == "NOOP" {
            writeLine(context: context, "250 2.0.0 OK NOOP")
        } else if upper == "QUIT" {
            writeLine(context: context, "221 2.0.0 Bye")
        }
    }

    private func drainDataPhaseIfTerminated(context: ChannelHandlerContext) {
        let terminator: [UInt8] = [0x0D, 0x0A, 0x2E, 0x0D, 0x0A] // "\r\n.\r\n"
        guard accumulated.readableBytesView.count >= terminator.count,
              Array(accumulated.readableBytesView.suffix(terminator.count)) == terminator
        else { return }
        accumulated.moveReaderIndex(forwardBy: accumulated.readableBytes)
        inData = false
        writeLine(context: context, "250 2.0.0 Queued as 12345")
    }

    private func writeLine(context: ChannelHandlerContext, _ text: String) {
        var buffer = context.channel.allocator.buffer(capacity: text.utf8.count + 2)
        buffer.writeString(text)
        buffer.writeString("\r\n")
        context.writeAndFlush(Self.wrapOutboundOut(buffer), promise: nil)
    }
}
