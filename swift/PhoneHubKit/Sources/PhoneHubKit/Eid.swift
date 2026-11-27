import Foundation
import CryptoKit

/// BLE ephemeral IDs for Better Together discovery. Port of `ble/eid.py`.
///
/// Source (EID = SHA256(seed ‖ BE64(periodStart))[:2], 15-min period, ±2 lookahead):
///   https://chromium.googlesource.com/chromium/src/+/a753229/components/cryptauth/raw_eid_generator_impl.cc
///   https://chromium.googlesource.com/chromium/src.git/+/71.0.3578.128/components/cryptauth/background_eid_generator.cc
public enum Eid {
    static let periodMs: Int64 = 15 * 60 * 1000
    static let lookahead = 2
    static let byteCount = 2

    public struct BeaconSeed {
        public let data: Data
        public let startTimeMs: Int64
        public let endTimeMs: Int64
        public init(data: Data, startTimeMs: Int64, endTimeMs: Int64) {
            self.data = data
            self.startTimeMs = startTimeMs
            self.endTimeMs = endTimeMs
        }
    }

    static func rawEid(seed: Data, startOfPeriodMs: Int64, extraEntropy: Data? = nil) -> Data {
        var toHash = seed
        if let e = extraEntropy { toHash += e }
        var be = startOfPeriodMs.bigEndian
        toHash += withUnsafeBytes(of: &be) { Data($0) }
        let digest = SHA256.hash(data: toHash)
        return Data(digest).prefix(byteCount)
    }

    private static func seedFor(_ tsMs: Int64, _ seeds: [BeaconSeed]) -> BeaconSeed? {
        seeds.first { tsMs >= $0.startTimeMs && tsMs <= $0.endTimeMs }
    }

    static func eidFor(_ tsMs: Int64, _ seeds: [BeaconSeed]) -> (eid: Data, periodStart: Int64)? {
        guard let seed = seedFor(tsMs, seeds) else { return nil }
        let offset = tsMs - seed.startTimeMs
        let periodStart = seed.startTimeMs + (offset / periodMs) * periodMs
        return (rawEid(seed: seed.data, startOfPeriodMs: periodStart), periodStart)
    }

    static func nearestEids(_ seeds: [BeaconSeed], nowMs: Int64) -> [(eid: Data, periodStart: Int64)] {
        var out: [(Data, Int64)] = []
        for i in (-lookahead)...lookahead {
            if let r = eidFor(nowMs + Int64(i) * periodMs, seeds) { out.append(r) }
        }
        return out
    }

    static func matches(advertisementServiceData: Data, remoteSeeds: [BeaconSeed], nowMs: Int64) -> Bool {
        let eid = advertisementServiceData.prefix(byteCount)
        return nearestEids(remoteSeeds, nowMs: nowMs).contains { $0.eid == eid }
    }

    static func generateBeaconSeeds(nowMs: Int64, num: Int = 2, windowDays: Int = 7) -> [BeaconSeed] {
        let window = Int64(windowDays) * 24 * 60 * 60 * 1000
        var start = nowMs - window
        var seeds: [BeaconSeed] = []
        for _ in 0..<num {
            var data = Data(count: 64)
            data.withUnsafeMutableBytes { _ = SecRandomCopyBytes(kSecRandomDefault, 64, $0.baseAddress!) }
            seeds.append(BeaconSeed(data: data, startTimeMs: start, endTimeMs: start + window))
            start += window
        }
        return seeds
    }
}
