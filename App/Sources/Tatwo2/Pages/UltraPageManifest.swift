// 照搬自 Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac/UltraPageManifest.swift；改動 3 行（原因：B2 移除文件架構卡的模式字樣）
import Foundation
import SwiftUI

struct TatwoOsManifestV1: Codable, Equatable {
    struct Section: Codable, Equatable, Identifiable {
        let id: String
        let title: String
        let items: [String]
    }

    let schema: String
    /// Logical os.md identity (e.g. `TATWO-ULTRAWORKos/os.md`); never a host absolute path.
    let sourceId: String
    let sourceSHA256: String
    let generatedAt: String
    let sections: [Section]
}

enum UltraArchitectureManifestLoadState: Equatable {
    case loaded(manifest: TatwoOsManifestV1, rawText: String)
    case missing
    case invalid(String)

    var text: String? {
        guard case let .loaded(_, rawText) = self else { return nil }
        return rawText
    }

    var manifest: TatwoOsManifestV1? {
        guard case let .loaded(manifest, _) = self else { return nil }
        return manifest
    }
}

enum UltraArchitectureManifestLoader {
    static let resourceName = "os-architecture-standard"
    static let resourceExtension = "md"

    static func loadBundledManifest() -> UltraArchitectureManifestLoadState {
        load(from: .module)
    }

    static func load(from bundle: Bundle) -> UltraArchitectureManifestLoadState {
        guard let url = bundle.url(
            forResource: resourceName,
            withExtension: resourceExtension
        ),
        let data = try? Data(contentsOf: url),
        let contents = String(data: data, encoding: .utf8),
        !contents.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return .missing
        }

        do {
            let manifest = try JSONDecoder().decode(TatwoOsManifestV1.self, from: data)
            return .loaded(manifest: manifest, rawText: contents)
        } catch {
            return .invalid("manifest JSON 無法解析：\(error.localizedDescription)")
        }
    }
}

struct UltraArchitectureManifestSourceCard: View {
    let manifest: UltraArchitectureManifestLoadState
    let compact: Bool
    @State private var isExpanded = false

    init(
        manifest: UltraArchitectureManifestLoadState = UltraArchitectureManifestLoader.loadBundledManifest(),
        compact: Bool
    ) {
        self.manifest = manifest
        self.compact = compact
    }

    var body: some View {
        GlassCard {
            DisclosureGroup(isExpanded: $isExpanded) {
                manifestContents
                    .padding(.top, 10)
            } label: {
                HStack(alignment: .center, spacing: compact ? 9 : 12) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: compact ? 15 : 18, weight: .bold))
                        .foregroundStyle(.cyan)

                    VStack(alignment: .leading, spacing: 3) {
                        Text("架構標準來源：os.md §9")
                            .font(compact ? .subheadline.weight(.black) : .headline.weight(.black))
                            .foregroundStyle(.primary)
                        Text("此 manifest 由 os.md §9 於 build 時打包；單一真相源＝os.md。")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 8)

                    Badge(manifest.manifest == nil ? "manifest 未打包" : "bundled manifest")
                }
                .contentShape(Rectangle())
            }
            .tint(.cyan)

            if manifest.text == nil {
                Label("manifest 未打包", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.orange)
                    .padding(.top, 8)
            }
        }
    }

    @ViewBuilder
    private var manifestContents: some View {
        if let text = manifest.text {
            ScrollView {
                Text(text)
                    .font(.system(size: compact ? 10.5 : 11.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: compact ? 260 : 360)
            .padding(10)
            .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
            )
        } else {
            Text("manifest 未打包")
                .font(.callout.weight(.bold))
                .foregroundStyle(.orange)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// 文件架構樹：登記 TATWO OS 文件分層（治理／待決／施工／規格）＋ App issue list 定位。
/// 真相源＝os.md；本卡只是 Ultra 分頁的可視化鏡像。
struct UltraDocumentArchitectureCard: View {
    @ObservedObject private var themeStore = TatwoThemeStore.shared
    var compact: Bool = false

    private var nodes: [UltraManualTreeNode] {
        [
            UltraManualTreeNode("os", "os.md — 治理憲法（身份組／硬規則／刪除鐵律／XXL）", children: [
                UltraManualTreeNode("os9", "§9 已確定架構標準 → 本頁 manifest 來源"),
                UltraManualTreeNode("osptr", "§5 指標 → issue.md")
            ]),
            UltraManualTreeNode("issue", "issue.md — 系統待決方向（藍圖；右側資訊卡／域設備／畫布…）", children: [
                UltraManualTreeNode("issueflow", "拍板後下放 → todo.md")
            ]),
            UltraManualTreeNode("todo", "todo.md — 已拍板施工清單（§A–§F，每天勾銷）"),
            UltraManualTreeNode("workos", "WORK_OS.md — App 功能規格合約（App repo/docs/tatwo/）"),
            UltraManualTreeNode("applist", "App /issue list — thread 最小單位工作事項（非系統層，不進 todo）")
        ]
    }

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: compact ? 8 : 10) {
                HStack(spacing: 10) {
                    Image(systemName: "square.stack.3d.up")
                        .font(.system(size: compact ? 15 : 18, weight: .black))
                        .foregroundStyle(LiquidGlassTokens.brandAccent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("文件架構")
                            .font(.system(size: compact ? 14 : 17, weight: .black, design: .rounded))
                        Text("治理 → 待決 → 施工 → 規格；單一真相源＝os.md")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                UltraManualTree(
                    title: "TATWO OS 文件分層",
                    nodes: nodes,
                    accent: LiquidGlassTokens.brandAccent)
            }
        }
    }
}
