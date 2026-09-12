import Foundation

// 來源：Packages/TatwoUltraworkCore/Sources/TatwoUltraworkCore/TatwoDevicePairingV1.swift:15-169
// 只保留 R1 配對碼 record 與 mint／validate／consume；2.0 使用 6 碼、300 秒。

struct TatwoDevicePairingCodeRecordV1: Codable, Sendable, Equatable {
    static let schemaName = "TatwoDevicePairingCodeRecordV1"
    static let ttlSeconds: TimeInterval = 300
    static let seedLength = 6

    let schema: String
    let seed: String
    let createdAt: Date
    let expiresAt: Date
    let consumedAt: Date?
    let createdBy: String
    let authorityPrimary: String
    let authorityEpoch: UInt64

    init(
        schema: String = TatwoDevicePairingCodeRecordV1.schemaName,
        seed: String,
        createdAt: Date,
        expiresAt: Date,
        consumedAt: Date? = nil,
        createdBy: String,
        authorityPrimary: String,
        authorityEpoch: UInt64
    ) {
        self.schema = schema
        self.seed = seed
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.consumedAt = consumedAt
        self.createdBy = createdBy
        self.authorityPrimary = authorityPrimary
        self.authorityEpoch = authorityEpoch
    }

    var isConsumed: Bool { consumedAt != nil }

    func isExpired(at now: Date) -> Bool {
        expiresAt <= now
    }
}

enum TatwoDevicePairingCodeEngineV1 {
    private static let seedAlphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")

    static func isValidSeedFormat(_ seed: String) -> Bool {
        guard seed.count == TatwoDevicePairingCodeRecordV1.seedLength else { return false }
        return seed.unicodeScalars.allSatisfy { scalar in
            (scalar.value >= 0x41 && scalar.value <= 0x5A)
                || (scalar.value >= 0x30 && scalar.value <= 0x39)
        }
    }

    static func mint(
        createdBy: String,
        authorityPrimary: String,
        authorityEpoch: UInt64,
        now: Date = Date(),
        ttlSeconds: TimeInterval = TatwoDevicePairingCodeRecordV1.ttlSeconds,
        seed: String? = nil,
        randomBytes: ((Int) -> [UInt8])? = nil
    ) throws -> TatwoDevicePairingCodeRecordV1 {
        let resolvedSeed: String
        if let seed {
            guard isValidSeedFormat(seed) else {
                throw TatwoDevicePairingErrorV1.invalidSeedFormat(seed)
            }
            resolvedSeed = seed
        } else {
            resolvedSeed = try generateSeed(randomBytes: randomBytes)
        }
        guard ttlSeconds > 0, ttlSeconds.isFinite else {
            throw TatwoDevicePairingErrorV1.invalidTTL
        }
        let createdByTrim = createdBy.trimmingCharacters(in: .whitespacesAndNewlines)
        let primaryTrim = authorityPrimary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !createdByTrim.isEmpty, !primaryTrim.isEmpty else {
            throw TatwoDevicePairingErrorV1.emptyAuthority
        }
        return TatwoDevicePairingCodeRecordV1(
            seed: resolvedSeed,
            createdAt: now,
            expiresAt: now.addingTimeInterval(ttlSeconds),
            consumedAt: nil,
            createdBy: createdByTrim,
            authorityPrimary: primaryTrim,
            authorityEpoch: authorityEpoch)
    }

    static func validate(
        seed: String,
        against record: TatwoDevicePairingCodeRecordV1,
        expectedPrimary: String? = nil,
        expectedEpoch: UInt64? = nil,
        now: Date = Date()
    ) throws {
        guard isValidSeedFormat(seed) else {
            throw TatwoDevicePairingErrorV1.invalidSeedFormat(seed)
        }
        guard seed == record.seed else {
            throw TatwoDevicePairingErrorV1.seedMismatch
        }
        if record.isConsumed {
            throw TatwoDevicePairingErrorV1.codeAlreadyConsumed
        }
        if record.isExpired(at: now) {
            throw TatwoDevicePairingErrorV1.codeExpired
        }
        if let expectedPrimary {
            let want = expectedPrimary.trimmingCharacters(in: .whitespacesAndNewlines)
            guard record.authorityPrimary == want, record.createdBy == want else {
                throw TatwoDevicePairingErrorV1.authorityMismatch
            }
        }
        if let expectedEpoch, record.authorityEpoch != expectedEpoch {
            throw TatwoDevicePairingErrorV1.authorityMismatch
        }
    }

    static func consume(
        seed: String,
        record: TatwoDevicePairingCodeRecordV1,
        expectedPrimary: String? = nil,
        expectedEpoch: UInt64? = nil,
        now: Date = Date()
    ) throws -> TatwoDevicePairingCodeRecordV1 {
        try validate(
            seed: seed,
            against: record,
            expectedPrimary: expectedPrimary,
            expectedEpoch: expectedEpoch,
            now: now)
        return TatwoDevicePairingCodeRecordV1(
            schema: record.schema,
            seed: record.seed,
            createdAt: record.createdAt,
            expiresAt: record.expiresAt,
            consumedAt: now,
            createdBy: record.createdBy,
            authorityPrimary: record.authorityPrimary,
            authorityEpoch: record.authorityEpoch)
    }

    private static func generateSeed(randomBytes: ((Int) -> [UInt8])?) throws -> String {
        let bytes: [UInt8]
        if let randomBytes {
            bytes = randomBytes(TatwoDevicePairingCodeRecordV1.seedLength)
        } else {
            var rng = SystemRandomNumberGenerator()
            bytes = (0..<TatwoDevicePairingCodeRecordV1.seedLength).map { _ in
                UInt8.random(in: 0...255, using: &rng)
            }
        }
        guard bytes.count >= TatwoDevicePairingCodeRecordV1.seedLength else {
            throw TatwoDevicePairingErrorV1.seedEntropyUnavailable
        }
        var chars: [Character] = []
        chars.reserveCapacity(TatwoDevicePairingCodeRecordV1.seedLength)
        for index in 0..<TatwoDevicePairingCodeRecordV1.seedLength {
            chars.append(seedAlphabet[Int(bytes[index]) % seedAlphabet.count])
        }
        return String(chars)
    }
}
