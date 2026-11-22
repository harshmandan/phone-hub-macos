import Foundation
import CryptoKit

/// Self-tests, mirroring the probe's Python tests. Run via the
/// `phonehubkit-selftest` executable (no XCTest needed, so it works with the
/// Command Line Tools toolchain). Throws on the first failure.
public enum SelfTest {
    struct Failure: Error { let message: String }

    static func check(_ cond: Bool, _ what: String) throws {
        if !cond { throw Failure(message: what) }
    }

    static func random(_ n: Int) -> Data {
        var d = Data(count: n)
        d.withUnsafeMutableBytes { _ = SecRandomCopyBytes(kSecRandomDefault, n, $0.baseAddress!) }
        return d
    }

    /// Cross-language check: decrypt a symmetric SecureMessage made elsewhere
    /// (e.g. the Python probe). Prints "<payloadHex> <metadataHex>".
    public static func unwrapHex(keyHex: String, blobHex: String) throws -> String {
        let (pt, meta) = try SecureMessage.unwrap(key: Data(hex: keyHex),
                                                  secureMessage: Data(hex: blobHex))
        return pt.hex + " " + meta.hex
    }

    public static func run() throws {
        try secureMessage()
        print("ok  securemessage symmetric + ECIES + GenericPublicKey")
        try channel()
        print("ok  key agreement + session keys + channel round-trip")
        try eid()
        print("ok  EID formula + discovery + look-ahead")
        try weave()
        print("ok  uWeave fragmentation + counter enforcement")
        try quickStart()
        print("ok  Quick Start QR + AES-GCM handshake round-trip")
        try ukey2()
        print("ok  UKEY2 handshake — both sides derive the same secret + auth")
        print("all passed")
    }

    static func secureMessage() throws {
        let key = random(32)
        let blob = SecureMessage.create(key: key, payload: Data("payload".utf8),
                                        publicMetadata: Data("meta".utf8))
        let (pt, meta) = try SecureMessage.unwrap(key: key, secureMessage: blob)
        try check(pt == Data("payload".utf8), "symmetric payload")
        try check(meta == Data("meta".utf8), "symmetric metadata")

        var bad = blob
        bad[bad.index(before: bad.endIndex)] ^= 1
        var tamperCaught = false
        do { _ = try SecureMessage.unwrap(key: key, secureMessage: bad) }
        catch { tamperCaught = true }
        try check(tamperCaught, "tamper should be rejected")

        let group = P256.KeyAgreement.PrivateKey()
        let ecies = try SecureMessage.encrypt(payload: Data("ecies".utf8), to: group.publicKey)
        try check(try SecureMessage.decrypt(secureMessage: ecies, with: group) == Data("ecies".utf8), "ecies round-trip")

        let priv = P256.KeyAgreement.PrivateKey()
        let gpk = SecureMessage.genericPublicKey(priv.publicKey)
        try check(try SecureMessage.parseGenericPublicKey(gpk).rawRepresentation == priv.publicKey.rawRepresentation, "GenericPublicKey round-trip")
    }

    static func channel() throws {
        let initiator = P256.KeyAgreement.PrivateKey()
        let responder = P256.KeyAgreement.PrivateKey()
        let rootI = try SecureMessage.masterKey(initiator, responder.publicKey)
        let rootR = try SecureMessage.masterKey(responder, initiator.publicKey)
        try check(rootI == rootR, "ECDH roots match")

        let keys = SessionKeys(rootSymmetricKey: rootI)
        try check(keys.initiator != keys.responder && keys.initiator.count == 32, "session keys split")

        let mac = SecureContext(sessionKeys: keys, role: .initiator)
        let phone = SecureContext(sessionKeys: keys, role: .responder)
        try check(try phone.decode(mac.encode(Data("hello from mac".utf8))) == Data("hello from mac".utf8), "mac→phone")
        try check(try phone.decode(mac.encode(Data("second".utf8))) == Data("second".utf8), "mac→phone 2")
        try check(try mac.decode(phone.encode(Data("hi from phone".utf8))) == Data("hi from phone".utf8), "phone→mac")

        let old = mac.encode(Data("x".utf8))
        _ = try phone.decode(old)
        var replayCaught = false
        do { _ = try phone.decode(old) } catch { replayCaught = true }
        try check(replayCaught, "replay rejected")
    }

    static func eid() throws {
        let ts = (1795000000000 / Eid.periodMs) * Eid.periodMs
        var toHash = Data("eidSeed".utf8)
        var be = ts.bigEndian
        toHash += withUnsafeBytes(of: &be) { Data($0) }
        let expect = Data(SHA256.hash(data: toHash)).prefix(2)
        try check(Eid.rawEid(seed: Data("eidSeed".utf8), startOfPeriodMs: ts) == expect, "EID formula")

        let now: Int64 = 1795000000000
        let phone = Eid.generateBeaconSeeds(nowMs: now)
        let (adv, _) = Eid.eidFor(now, phone)!
        try check(Eid.matches(advertisementServiceData: adv + Data([0, 1]), remoteSeeds: phone, nowMs: now), "own EID matches")
        try check(!Eid.matches(advertisementServiceData: adv, remoteSeeds: Eid.generateBeaconSeeds(nowMs: now), nowMs: now), "other seeds don't match")
        try check(Eid.nearestEids(phone, nowMs: now).count == 5, "look-ahead count")
    }

    static func quickStart() throws {
        let b = QuickStart.newBootstrap()
        let url = QuickStart.qrURL(b)
        try check(url.hasPrefix("https://signin.google/qs/") && url.contains("?key="), "QR URL shape")
        try check(b.advertisingId.count == 10 && b.sharedSecret.count == 32, "bootstrap sizes")

        // handshake round-trip: target builds, verify as the target's message
        let msg = try QuickStart.buildHandshakeMessage(
            authString: "auth-token-xyz", secret: b.sharedSecret, role: QuickStart.roleTarget)
        try check(QuickStart.verifyHandshakeMessage(
            msg, secret: b.sharedSecret, expectedRole: QuickStart.roleTarget,
            expectedAuthString: "auth-token-xyz"), "handshake verifies")
        // wrong secret fails
        try check(!QuickStart.verifyHandshakeMessage(
            msg, secret: QuickStart.randomData(32), expectedRole: QuickStart.roleTarget,
            expectedAuthString: "auth-token-xyz"), "wrong secret rejected")
        // wrong auth string fails
        try check(!QuickStart.verifyHandshakeMessage(
            msg, secret: b.sharedSecret, expectedRole: QuickStart.roleTarget,
            expectedAuthString: "nope"), "wrong auth string rejected")
    }

    static func ukey2() throws {
        let (client, server) = try Ukey2.selfHandshake()
        try check(client == server, "UKEY2 both sides match")
        try check(client.nextSecret.count == 32 && !client.authString.isEmpty, "UKEY2 outputs sized")
        // a second handshake yields different secrets
        let (c2, _) = try Ukey2.selfHandshake()
        try check(c2.nextSecret != client.nextSecret, "fresh handshake differs")
    }

    static func weave() throws {
        for size in [1, 18, 19, 20, 100, 1000] {
            let gen = Weave.PacketGenerator()
            let recv = Weave.PacketReceiver()
            if case .control(let cmd) = try recv.receive(gen.connectionRequest()) {
                try check(cmd == Weave.connectionRequest, "control command")
            } else { throw Failure(message: "expected control packet") }
            let msg = random(size)
            var out = Data()
            for p in gen.encodeDataMessage(msg) {
                try check(p.count <= Weave.defaultMaxPacketSize, "packet fits MTU")
                if case .message(let m) = try recv.receive(p) { out = m }
            }
            try check(out == msg, "weave round-trip size \(size)")
        }
        let gen = Weave.PacketGenerator()
        let recv = Weave.PacketReceiver()
        _ = try recv.receive(gen.connectionRequest())
        let packets = gen.encodeDataMessage(random(200))
        _ = try recv.receive(packets[0])
        var seqCaught = false
        do { _ = try recv.receive(packets[2]) } catch { seqCaught = true }
        try check(seqCaught, "dropped packet breaks counter")
    }
}
