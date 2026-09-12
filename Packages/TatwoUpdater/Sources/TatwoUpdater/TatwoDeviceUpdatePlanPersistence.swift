import CryptoKit
import Foundation

public enum TatwoDeviceUpdatePlanEventKindV1: String, Codable, Hashable, Sendable {
    case created
    case approved
    case devicePreflighted
    case deviceOutcomeRecorded
}

public struct TatwoDeviceUpdatePlanEventV1: Codable, Hashable, Sendable {
    public let kind: TatwoDeviceUpdatePlanEventKindV1
    public let plan: TatwoDeviceUpdatePlanV1
    public let deviceID: String?
    public let observedAt: Date

    public init(
        kind: TatwoDeviceUpdatePlanEventKindV1,
        plan: TatwoDeviceUpdatePlanV1,
        deviceID: String?,
        observedAt: Date
    ) {
        self.kind = kind
        self.plan = plan
        self.deviceID = deviceID
        self.observedAt = observedAt
    }
}

public struct TatwoDeviceUpdatePlanRecordV1: Codable, Hashable, Sendable {
    public let schemaVersion: Int
    public let sequence: Int
    public let previousRecordSHA256: String
    public let payloadSHA256: String
    public let recordSHA256: String
    public let event: TatwoDeviceUpdatePlanEventV1

    public init(
        sequence: Int,
        previousRecordSHA256: String,
        payloadSHA256: String,
        recordSHA256: String,
        event: TatwoDeviceUpdatePlanEventV1
    ) {
        schemaVersion = 1
        self.sequence = sequence
        self.previousRecordSHA256 = previousRecordSHA256
        self.payloadSHA256 = payloadSHA256
        self.recordSHA256 = recordSHA256
        self.event = event
    }
}

public protocol TatwoDeviceUpdatePlanPersistencePort: AnyObject {
    func loadValidatedRecords() throws -> [TatwoDeviceUpdatePlanRecordV1]
    @discardableResult
    func append(_ event: TatwoDeviceUpdatePlanEventV1) throws -> TatwoDeviceUpdatePlanRecordV1
}

public enum TatwoDeviceUpdatePlanPersistenceError: Error, Equatable, Sendable {
    case invalidRoot
    case rootMissing
    case unsafeLogSymbolicLink
    case corruptRecord(line: Int)
    case invalidSchema(sequence: Int)
    case invalidSequence(expected: Int, actual: Int)
    case invalidPreviousHash(sequence: Int)
    case invalidPayloadHash(sequence: Int)
    case invalidRecordHash(sequence: Int)
    case truncatedLog
}

public final class TatwoFileBackedDeviceUpdatePlanPersistence:
    TatwoDeviceUpdatePlanPersistencePort
{
    public static let zeroHash = String(repeating: "0", count: 64)

    private let fileManager: FileManager
    private let logURL: URL
    private let lock = NSLock()

    public init(
        rootURL: URL,
        createRootIfMissing: Bool = false,
        fileManager: FileManager = .default
    ) throws {
        guard rootURL.isFileURL, rootURL.path.hasPrefix("/") else {
            throw TatwoDeviceUpdatePlanPersistenceError.invalidRoot
        }
        self.fileManager = fileManager

        var isDirectory: ObjCBool = false
        if !fileManager.fileExists(atPath: rootURL.path, isDirectory: &isDirectory) {
            guard createRootIfMissing else {
                throw TatwoDeviceUpdatePlanPersistenceError.rootMissing
            }
            try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
            isDirectory = true
        }
        guard isDirectory.boolValue else {
            throw TatwoDeviceUpdatePlanPersistenceError.invalidRoot
        }

        let canonicalRoot = rootURL.resolvingSymlinksInPath().standardizedFileURL
        logURL = canonicalRoot.appendingPathComponent("device-update-plans.v1.jsonl")
        if fileManager.fileExists(atPath: logURL.path),
           (try? fileManager.destinationOfSymbolicLink(atPath: logURL.path)) != nil
        {
            throw TatwoDeviceUpdatePlanPersistenceError.unsafeLogSymbolicLink
        }
    }

    public func loadValidatedRecords() throws -> [TatwoDeviceUpdatePlanRecordV1] {
        lock.lock()
        defer { lock.unlock() }
        return try loadValidatedRecordsLocked()
    }

    @discardableResult
    public func append(
        _ event: TatwoDeviceUpdatePlanEventV1
    ) throws -> TatwoDeviceUpdatePlanRecordV1 {
        lock.lock()
        defer { lock.unlock() }

        let records = try loadValidatedRecordsLocked()
        let record = try Self.makeRecord(
            sequence: records.count + 1,
            previousHash: records.last?.recordSHA256 ?? Self.zeroHash,
            event: event
        )
        let encoded = try Self.encoder.encode(record) + Data([0x0A])

        if !fileManager.fileExists(atPath: logURL.path) {
            guard fileManager.createFile(atPath: logURL.path, contents: nil) else {
                throw TatwoDeviceUpdatePlanPersistenceError.invalidRoot
            }
        }
        if (try? fileManager.destinationOfSymbolicLink(atPath: logURL.path)) != nil {
            throw TatwoDeviceUpdatePlanPersistenceError.unsafeLogSymbolicLink
        }

        let handle = try FileHandle(forWritingTo: logURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: encoded)
        try handle.synchronize()
        return record
    }

    private func loadValidatedRecordsLocked() throws -> [TatwoDeviceUpdatePlanRecordV1] {
        guard fileManager.fileExists(atPath: logURL.path) else {
            return []
        }
        if (try? fileManager.destinationOfSymbolicLink(atPath: logURL.path)) != nil {
            throw TatwoDeviceUpdatePlanPersistenceError.unsafeLogSymbolicLink
        }

        let data = try Data(contentsOf: logURL)
        guard !data.isEmpty else {
            return []
        }
        guard data.last == 0x0A else {
            throw TatwoDeviceUpdatePlanPersistenceError.truncatedLog
        }

        let lines = data.split(separator: 0x0A, omittingEmptySubsequences: true)
        var records: [TatwoDeviceUpdatePlanRecordV1] = []
        records.reserveCapacity(lines.count)
        var previousHash = Self.zeroHash

        for (offset, line) in lines.enumerated() {
            let record: TatwoDeviceUpdatePlanRecordV1
            do {
                record = try Self.decoder.decode(
                    TatwoDeviceUpdatePlanRecordV1.self,
                    from: Data(line)
                )
            } catch {
                throw TatwoDeviceUpdatePlanPersistenceError.corruptRecord(line: offset + 1)
            }
            try Self.validate(
                record,
                expectedSequence: offset + 1,
                expectedPreviousHash: previousHash
            )
            records.append(record)
            previousHash = record.recordSHA256
        }
        return records
    }

    private static func makeRecord(
        sequence: Int,
        previousHash: String,
        event: TatwoDeviceUpdatePlanEventV1
    ) throws -> TatwoDeviceUpdatePlanRecordV1 {
        let payloadHash = sha256(try encoder.encode(event))
        let hashBody = TatwoDeviceUpdatePlanRecordHashBodyV1(
            schemaVersion: 1,
            sequence: sequence,
            previousRecordSHA256: previousHash,
            payloadSHA256: payloadHash,
            event: event
        )
        return TatwoDeviceUpdatePlanRecordV1(
            sequence: sequence,
            previousRecordSHA256: previousHash,
            payloadSHA256: payloadHash,
            recordSHA256: sha256(try encoder.encode(hashBody)),
            event: event
        )
    }

    private static func validate(
        _ record: TatwoDeviceUpdatePlanRecordV1,
        expectedSequence: Int,
        expectedPreviousHash: String
    ) throws {
        guard record.schemaVersion == 1 else {
            throw TatwoDeviceUpdatePlanPersistenceError.invalidSchema(sequence: record.sequence)
        }
        guard record.sequence == expectedSequence else {
            throw TatwoDeviceUpdatePlanPersistenceError.invalidSequence(
                expected: expectedSequence,
                actual: record.sequence
            )
        }
        guard record.previousRecordSHA256 == expectedPreviousHash else {
            throw TatwoDeviceUpdatePlanPersistenceError.invalidPreviousHash(
                sequence: record.sequence
            )
        }

        let payloadHash = sha256(try encoder.encode(record.event))
        guard payloadHash == record.payloadSHA256 else {
            throw TatwoDeviceUpdatePlanPersistenceError.invalidPayloadHash(
                sequence: record.sequence
            )
        }
        let hashBody = TatwoDeviceUpdatePlanRecordHashBodyV1(
            schemaVersion: record.schemaVersion,
            sequence: record.sequence,
            previousRecordSHA256: record.previousRecordSHA256,
            payloadSHA256: record.payloadSHA256,
            event: record.event
        )
        guard sha256(try encoder.encode(hashBody)) == record.recordSHA256 else {
            throw TatwoDeviceUpdatePlanPersistenceError.invalidRecordHash(
                sequence: record.sequence
            )
        }
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }()
}

private struct TatwoDeviceUpdatePlanRecordHashBodyV1: Codable {
    let schemaVersion: Int
    let sequence: Int
    let previousRecordSHA256: String
    let payloadSHA256: String
    let event: TatwoDeviceUpdatePlanEventV1
}
