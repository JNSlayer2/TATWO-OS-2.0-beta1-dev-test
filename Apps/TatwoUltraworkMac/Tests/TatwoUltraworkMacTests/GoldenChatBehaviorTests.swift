import CryptoKit
import Foundation
import XCTest
import TatwoUltraworkCore
@testable import TatwoUltraworkMac

/// C0 freezes the projection format and bytes before ChatPageModel facade work.
/// The fixture rows intentionally contain only digests of observable payloads.
final class GoldenChatBehaviorTests: XCTestCase {
    private static let sceneIDs = [
        "send", "stream", "stop", "resume", "slash", "plg",
        "engine_switch", "reattach", "cold_start", "orphan", "queued_turn",
    ]

    func testAllRequiredScenesReplayByteIdentical() throws {
        for sceneID in Self.sceneIDs {
            let url = try goldenRoot().appendingPathComponent(sceneID)
                .appendingPathComponent("transcript.jsonl")
            let frozen = try Data(contentsOf: url)
            let replayed = try replay(sceneID: sceneID, frozen: frozen)
            XCTAssertEqual(replayed, frozen, "golden drift: \(sceneID)")
        }
    }

    func testTranscriptMetaHashesMatchBytes() throws {
        for sceneID in Self.sceneIDs {
            let directory = try goldenRoot().appendingPathComponent(sceneID)
            let transcript = try Data(contentsOf: directory.appendingPathComponent("transcript.jsonl"))
            let metaData = try Data(contentsOf: directory.appendingPathComponent("transcript.meta.json"))
            let meta = try XCTUnwrap(JSONSerialization.jsonObject(with: metaData) as? [String: Any])
            XCTAssertEqual(meta["scene_id"] as? String, sceneID)
            XCTAssertEqual(meta["transcript_hash"] as? String, sha256(transcript))
            XCTAssertTrue(meta["verifier_id"] is NSNull)
        }
    }

    func testRowsObeyFrozenSchemaAndDeterminismRules() throws {
        let allowedKinds = Set([
            "TurnStarted", "ItemDelta", "ItemCompleted", "TurnCompleted",
            "ApprovalRequested", "Stop", "Resume", "Slash", "PLG",
            "EngineSwitch", "Reattach", "ColdStart", "Orphan", "QueuedTurn",
        ])
        for sceneID in Self.sceneIDs {
            let data = try Data(contentsOf: try goldenRoot()
                .appendingPathComponent(sceneID).appendingPathComponent("transcript.jsonl"))
            XCTAssertEqual(data.last, 0x0A)
            let lines = String(decoding: data, as: UTF8.self).split(separator: "\n")
            for (index, line) in lines.enumerated() {
                let row = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
                XCTAssertEqual(row["seq"] as? Int, index + 1)
                XCTAssertEqual(row["t_ms"] as? Int, index * 10)
                XCTAssertTrue(allowedKinds.contains(try XCTUnwrap(row["kind"] as? String)))
                XCTAssertEqual((row["threadID"] as? String)?.isEmpty, false)
                XCTAssertEqual((row["payload_digest"] as? String)?.count, 64)
                let spine = try XCTUnwrap(row["spine"] as? [String: Any])
                XCTAssertEqual(spine["threadID"] as? String, row["threadID"] as? String)
                for forbidden in ["captured_at", "pid", "transcript_hash", "absolute_path"] {
                    XCTAssertNil(row[forbidden])
                }
            }
        }
    }

    @MainActor
    func testChatPageModelRemainsTestConstructibleWithFixtureStore() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("g3-c0-model-smoke", isDirectory: true)
        try? FileManager.default.removeItem(at: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = ChatPageModel(
            environment: [
                "XCTestConfigurationFilePath": "GoldenChatBehaviorTests",
                "TATWO_ULTRAWORK_CHAT_ENABLE_CLI_RUNTIME": "0",
                "TATWO_ULTRAWORK_CHAT_CODEX_MIRROR": "0",
            ],
            store: TatwoNativeChatStore(
                url: root.appendingPathComponent("native-chat.json"),
                fallbackURLs: [], mirrorsToUnifiedLedger: false),
            transcriptJournalStore: ChatTranscriptJournalDiskStore(
                fileURL: root.appendingPathComponent("journal.json")),
            goalRunStore: TatwoGoalRunStore(directoryURL: root.appendingPathComponent("goals")))
        for _ in 0..<200 where model.isLoadingStore {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertFalse(model.isLoadingStore)
        XCTAssertTrue(model.messages.isEmpty)
    }

    private func replay(sceneID: String, frozen: Data) throws -> Data {
        // Decode and canonicalize every projected event. This catches ordering,
        // whitespace, key-order, and schema drift rather than comparing parsed objects.
        let rows = String(decoding: frozen, as: UTF8.self).split(separator: "\n")
        var output = Data()
        for line in rows {
            let object = try JSONSerialization.jsonObject(with: Data(line.utf8))
            let encoded = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
            output.append(encoded)
            output.append(0x0A)
        }
        return output
    }

    private func goldenRoot() throws -> URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() }
        let root = url.appendingPathComponent("harness-exam/g3/golden", isDirectory: true)
        guard FileManager.default.fileExists(atPath: root.path) else {
            throw XCTSkip("golden root unavailable: \(root.lastPathComponent)")
        }
        return root
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
