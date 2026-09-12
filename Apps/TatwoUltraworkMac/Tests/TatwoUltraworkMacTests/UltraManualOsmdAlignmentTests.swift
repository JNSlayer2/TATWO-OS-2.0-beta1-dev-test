import XCTest
@testable import TatwoUltraworkMac

/// 防漂移（os.md §9 meta-rule）：UltraPage 架構手冊是 os.md 架構標準的衍生鏡像。
/// 若有人增刪/改動頂層章節而未同步 os.md §9 + osmdDerivedChapterIDs 契約，此測試會紅，
/// 強制人與 AI 回到單一真相源 os.md，而非讓 UltraPage hardcode 悄悄漂移。
final class UltraManualOsmdAlignmentTests: XCTestCase {
    /// §9 may gain sections as architecture is ratified (TODO rule: settled
    /// closed-loop architecture is promoted into os.md §9). The drift this
    /// test must catch is a *gap, duplicate or reorder* — not growth. So the
    /// expectation is derived: contiguous from 9.1, no holes.
    private func contiguousSectionIDs(count: Int) -> [String] {
        (1...max(count, 1)).map { "9.\($0)" }
    }

    func testBundledManifestHasValidSchemaAndRequiredSectionIDs() throws {
        let manifest0 = try XCTUnwrap(UltraManualData.bundledManifest)
        let numbered0 = manifest0.sections.filter { $0.id != "meta-rule" }
        XCTAssertGreaterThanOrEqual(numbered0.count, 7, "§9 不得少於既有已定案章節數")
        let expectedSectionIDs = contiguousSectionIDs(count: numbered0.count)
        let manifest = try XCTUnwrap(
            UltraManualData.bundledManifest,
            "UltraPage 必須從 SwiftPM bundled os-manifest 載入，不得回退到 os.md runtime 讀取。"
        )
        XCTAssertEqual(manifest.schema, "TatwoOsManifestV1")
        XCTAssertFalse(manifest.sourceSHA256.isEmpty)
        XCTAssertFalse(manifest.generatedAt.isEmpty)
        XCTAssertEqual(
            manifest.sections.filter { $0.id != "meta-rule" }.map(\.id),
            expectedSectionIDs
        )
        XCTAssertTrue(manifest.sections.allSatisfy { !$0.title.isEmpty && !$0.items.isEmpty })
    }

    func testRenderedChaptersMatchBundledManifest() throws {
        let manifest = try XCTUnwrap(UltraManualData.bundledManifest)
        let renderedIDs = UltraManualData.manifestChapters.map(\.id)
        let manifestIDs = manifest.sections.map(\.id)
        XCTAssertEqual(
            renderedIDs,
            manifestIDs,
            "UltraPage 渲染章節必須直接由 bundled manifest 投影。"
        )
        let numbered = manifest.sections.filter { $0.id != "meta-rule" }.map(\.id)
        XCTAssertEqual(
            UltraManualData.osmdDerivedChapterIDs,
            numbered,
            "osmdDerivedChapterIDs 必須等於 manifest 的編號章節，且隨 os.md §9 成長自動對齊。"
        )
        XCTAssertEqual(numbered, contiguousSectionIDs(count: numbered.count), "§9 章節須自 9.1 起連續無斷號")
    }

    func testEveryDerivedChapterHasContent() {
        // 每章至少要有標題與白話說明，避免 manifest 投影出現空殼章節。
        for chapter in UltraManualData.manifestChapters {
            XCTAssertFalse(chapter.title.trimmingCharacters(in: .whitespaces).isEmpty, "章節 \(chapter.id) 缺標題")
            XCTAssertFalse(chapter.plainText.trimmingCharacters(in: .whitespaces).isEmpty, "章節 \(chapter.id) 缺白話說明")
        }
    }
}
