import CryptoKit
import Foundation
import XCTest

final class GoldenBotPageTests: XCTestCase {
    private static let sceneIDs = [
        "rail-tree", "rail-collapsed", "rail-empty", "thread",
        "group-sandbox", "space-full", "space-compact", "space-status",
        "add-space", "quick-card", "settings-9row", "stress",
    ]

    func testCapturedGoldensReplayBytesAndSchema() throws {
        let root = try goldenRoot()
        let manifestURL = root.appendingPathComponent("manifest.json")
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            throw XCTSkip("G4 Bot goldens have not been captured")
        }

        let manifest = try jsonObject(at: manifestURL)
        XCTAssertEqual(manifest["schema"] as? String, "TatwoBotGoldenManifestV1")
        XCTAssertEqual(manifest["exam_id"] as? String, "g4")
        XCTAssertEqual(manifest["frozen"] as? Bool, true)
        XCTAssertTrue(manifest["verifier_id"] is NSNull)

        let scenes = try XCTUnwrap(manifest["scenes"] as? [[String: Any]])
        XCTAssertEqual(scenes.compactMap { $0["id"] as? String }, Self.sceneIDs)

        for (index, sceneID) in Self.sceneIDs.enumerated() {
            let scene = scenes[index]
            let directory = root.appendingPathComponent(sceneID, isDirectory: true)
            let pngURL = directory.appendingPathComponent("bot.png")
            let metaURL = directory.appendingPathComponent("screenshot.meta.json")
            let viewStateURL = directory.appendingPathComponent("view_state.json")

            let png = try Data(contentsOf: pngURL)
            XCTAssertFalse(png.isEmpty, "empty PNG: \(sceneID)")
            let screenshotHash = sha256(png)
            XCTAssertEqual(scene["screenshot_hash"] as? String, screenshotHash)

            let meta = try jsonObject(at: metaURL)
            XCTAssertEqual(meta["schema"] as? String, "TatwoBotGoldenScreenshotMetaV1")
            XCTAssertEqual(meta["scene_id"] as? String, sceneID)
            XCTAssertEqual(meta["surface"] as? String, "Bot")
            XCTAssertEqual(meta["path"] as? String, "golden/\(sceneID)/bot.png")
            XCTAssertEqual(meta["screenshot_hash"] as? String, screenshotHash)
            XCTAssertEqual(
                meta["screenshot_sidecar_hash"] as? String,
                try canonicalHash(meta, excluding: ["screenshot_sidecar_hash", "captured_at", "verifier_id"])
            )

            let viewState = try jsonObject(at: viewStateURL)
            XCTAssertEqual(viewState["schema"] as? String, "TatwoBotGoldenViewStateV1")
            XCTAssertEqual(viewState["scene_id"] as? String, sceneID)
            XCTAssertTrue((viewState["fixture_id"] as? String)?.hasPrefix("fixture-") == true)
            XCTAssertEqual(meta["run_id"] as? String, viewState["run_id"] as? String)
            XCTAssertEqual(meta["viewport"] as? NSDictionary, viewState["viewport"] as? NSDictionary)
            let viewStateHash = try canonicalHash(
                viewState, excluding: ["view_state_hash", "captured_at", "verifier_id"]
            )
            XCTAssertEqual(viewState["view_state_hash"] as? String, viewStateHash)
            XCTAssertEqual(scene["view_state_hash"] as? String, viewStateHash)

            let bundle: [String: Any] = [
                "scene_id": sceneID,
                "screenshot_hash": screenshotHash,
                "view_state_hash": viewStateHash,
            ]
            XCTAssertEqual(scene["bundle_hash"] as? String, try canonicalHash(bundle))
            XCTAssertEqual(
                scene["screenshot_meta_path"] as? String,
                "golden/\(sceneID)/screenshot.meta.json"
            )
            XCTAssertEqual(
                scene["view_state_path"] as? String,
                "golden/\(sceneID)/view_state.json"
            )

            let viewport = try XCTUnwrap(meta["viewport"] as? [String: Any])
            XCTAssertEqual(viewport["scale"] as? Int, 2)
            XCTAssertEqual(viewport["width"] as? Int, sceneID == "stress" ? 980 : 1440)
            XCTAssertEqual(viewport["height"] as? Int, sceneID == "stress" ? 720 : 900)
        }

        XCTAssertEqual(
            manifest["manifest_hash"] as? String,
            try canonicalHash(manifest, excluding: ["manifest_hash", "verifier_id", "captured_at"])
        )
    }

    private func goldenRoot() throws -> URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() }
        let root = url.appendingPathComponent("harness-exam/g4/golden", isDirectory: true)
        guard FileManager.default.fileExists(atPath: root.path) else {
            throw XCTSkip("G4 Bot goldens have not been captured")
        }
        return root
    }

    private func jsonObject(at url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func canonicalHash(
        _ object: [String: Any],
        excluding keys: Set<String> = []
    ) throws -> String {
        var canonical = object
        for key in keys {
            canonical.removeValue(forKey: key)
        }
        let data = try JSONSerialization.data(
            withJSONObject: canonical,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        return sha256(data)
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
