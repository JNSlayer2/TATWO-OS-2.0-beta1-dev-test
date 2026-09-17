// 照搬自 Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac/UltraPageManifest.swift；改動 3 行（原因：B2 移除文件架構卡的模式字樣）
import Foundation
import SwiftUI
import CryptoKit

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
    // W75: project the public installation template, never the retired 1.0 manifest.
    static let resourceName = "os"
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

        return projectConstitution(contents)
    }

    static func projectConstitution(_ contents: String) -> UltraArchitectureManifestLoadState {
        var sections: [TatwoOsManifestV1.Section] = []
        var sectionID: String?
        var title = ""
        var items: [String] = []
        func finishSection() {
            guard let id = sectionID else { return }
            sections.append(.init(id: id, title: title, items: items))
        }
        for line in contents.components(separatedBy: .newlines) {
            if line.hasPrefix("## ") {
                finishSection()
                let heading = String(line.dropFirst(3))
                guard let separator = heading.range(of: ". "),
                      let number = Int(heading[..<separator.lowerBound]) else {
                    return .invalid("憲法範本章節標題無法解析")
                }
                sectionID = String(number)
                title = String(heading[separator.upperBound...])
                items = []
            } else if sectionID != nil, !line.trimmingCharacters(in: .whitespaces).isEmpty {
                items.append(line)
            }
        }
        finishSection()
        guard sections.map(\.id) == (0...11).map({ String($0) }),
              sections.allSatisfy({ !$0.title.isEmpty && !$0.items.isEmpty }),
              contents.hasPrefix("# TATWO OS 憲法（v4") else {
            return .invalid("憲法範本須包含 v4 的 §0–§11")
        }
        let manifest = TatwoOsManifestV1(
            schema: "TatwoConstitutionTemplateV4",
            sourceId: "App/Resources/os.md",
            sourceSHA256: SHA256.hash(data: Data(contents.utf8)).map { String(format: "%02x", $0) }.joined(),
            generatedAt: "",
            sections: sections
        )
        return .loaded(manifest: manifest, rawText: contents)
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
                        Text("憲法 v4 安裝範本")
                            .font(compact ? .subheadline.weight(.black) : .headline.weight(.black))
                            .foregroundStyle(.primary)
                        Text("內建公開範本；生效規則以入口憲法為準。")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 8)

                    Badge(manifest.manifest == nil ? "範本不可用" : "內建範本")
                }
                .contentShape(Rectangle())
            }
            .tint(.cyan)

            if manifest.text == nil {
                Label("範本不可用", systemImage: "exclamationmark.triangle.fill")
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
            Text("範本不可用")
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
