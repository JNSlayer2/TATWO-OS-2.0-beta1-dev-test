import Foundation
import SwiftUI
import TatwoUltraworkCore

/// UltraPage 架構手冊的 build-time manifest 投影。
///
/// os.md（外接卷）只在 scripts/tatwo-osmd-manifest.mjs 執行時被讀取；App runtime
/// 只讀 SwiftPM 內嵌的 TatwoOsManifestV1，不假設外接卷存在。
enum UltraManualData {
    /// 維持舊測試/呼叫端的契約名稱，但現在完全由 bundled manifest 衍生。
    static var osmdDerivedChapterIDs: [String] {
        bundledManifest?.sections
            .filter { $0.id != "meta-rule" }
            .map(\.id) ?? []
    }

    static var bundledManifest: TatwoOsManifestV1? {
        UltraArchitectureManifestLoader.loadBundledManifest().manifest
    }

    /// UltraPage 的唯一章節資料來源：SwiftPM bundled os-manifest JSON。
    static var manifestChapters: [UltraManualChapter] {
        guard let manifest = bundledManifest else { return [] }
        return manifest.sections.enumerated().map { index, section in
            makeChapter(index: index, section: section)
        }
    }

    private static let symbols = [
        "arrow.triangle.2.circlepath", "puzzlepiece.extension.fill", "brain.head.profile",
        "person.3.sequence.fill", "shippingbox.fill", "graduationcap.fill",
        "point.3.filled.connected.trianglepath.dotted", "arrow.down.forward.and.arrow.up.backward.rectangle.fill"
    ]

    private static let accents: [Color] = [.cyan, .mint, .purple, .blue, .orange, .pink, .teal, .indigo]
    private static let detailSymbols = ["1.circle.fill", "2.circle.fill", "3.circle.fill", "4.circle.fill"]

    private static func makeChapter(
        index: Int,
        section: TatwoOsManifestV1.Section
    ) -> UltraManualChapter {
        let items = section.items.map(displayText)
        let title = displayText(section.title)
        let outline = items.first ?? title
        let plainText = items.joined(separator: " ")
        let detailItems = items.enumerated().map { itemIndex, item in
            UltraManualDetail(
                id: "\(section.id)-item-\(itemIndex + 1)",
                symbol: detailSymbols[itemIndex % detailSymbols.count],
                title: itemTitle(item, index: itemIndex),
                text: item
            )
        }
        let diagram = Array(items.prefix(5))
        let treeChildren = items.enumerated().map { itemIndex, item in
            UltraManualTreeNode("\(section.id)-tree-\(itemIndex + 1)", item)
        }

        return UltraManualChapter(
            id: section.id,
            number: String(format: "%02d", index),
            title: title,
            outline: outline,
            plainText: plainText,
            symbol: symbols[index % symbols.count],
            accent: accents[index % accents.count],
            details: detailItems,
            diagram: diagram,
            tree: [UltraManualTreeNode(section.id, title, children: treeChildren)]
        )
    }

    private static func displayText(_ text: String) -> String {
        text
            .replacingOccurrences(of: "**", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func itemTitle(_ item: String, index: Int) -> String {
        let firstClause = item.split(separator: "：", maxSplits: 1).first.map(String.init) ?? item
        let title = firstClause.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? "條目 \(index + 1)" : title
    }
}

enum WorkOSPlanLoopsGoalBlueprintFactory {
    static func make(contract: TatwoWorkOSContractV1) -> WorkOSPlanLoopsGoalBlueprint {
        let main = mainlineNodes(contract: contract)
        let branches = branchNodes(contract: contract)
        let verdicts = verdictNodes()
        let receipts = receiptNode(contract: contract)
        let nodes = main + branches + verdicts + receipts
        return WorkOSPlanLoopsGoalBlueprint(
            nodes: nodes,
            connectors: connectors(nodes: nodes, contract: contract),
            receiptTags: receiptTags(contract: contract),
            modeSummary: modeSummary(contract: contract)
        )
    }

    private static func mainlineNodes(contract: TatwoWorkOSContractV1) -> [WorkOSPlanLoopsGoalNode] {
        [
            node("task", "任務開始", "人類目標\n禁區 / 成功樣貌", "IN", .green, CGRect(x: 238, y: 178, width: 120, height: 72), .mainline),
            node("plan", "Plan", "主導定路線\n拆驗收標準", "主導", .red, CGRect(x: 392, y: 178, width: 130, height: 72), .mainline),
            node("loops", "Loops", "副審帶 sub\n支線自主跑", "循環", .yellow, CGRect(x: 558, y: 178, width: 196, height: 72), .mainline),
            node("goal", "Goal", "主導驗收\n收斂回主線", "驗收", .red, CGRect(x: 808, y: 178, width: 132, height: 72), .mainline),
            node("done", "完工", "交給人類\n列未驗項", "OUT", .green, CGRect(x: 970, y: 178, width: 124, height: 72), .mainline)
        ]
    }

    private static func responsibilityNodes(contract: TatwoWorkOSContractV1) -> [WorkOSPlanLoopsGoalNode] {
        [
            node("lead-plan-duty", "主導責任", "定主線架構\n定驗收標準\n限制改動邊界", "Plan", .blue, CGRect(x: 192, y: 34, width: 216, height: 78), .responsibility),
            node("supervisor-duty", "副審 + Sub", "副審盯支線偏航\nSub 跑反例與工具\n只交證據不自決", "Loops", .purple, CGRect(x: 430, y: 28, width: 236, height: 84), .responsibility),
            node("lead-goal-duty", "主導驗收", "檢查 loops 是否離題\n收斂未驗項\n通過才交人類", "Goal", .blue, CGRect(x: 750, y: 46, width: 222, height: 84), .responsibility)
        ]
    }

    private static func branchNodes(contract: TatwoWorkOSContractV1) -> [WorkOSPlanLoopsGoalNode] {
        let branches = branchBlueprints(contract: contract)
        let rects = branchRects(count: branches.count)
        return zip(branches, rects).map { branch, rect in
            node(branch.id, branch.title, branch.subtitle, branch.kicker, branch.color, rect, .branch)
        }
    }

    private static func verdictNodes() -> [WorkOSPlanLoopsGoalNode] {
        [
            node("supervisor-fail", "副審駁回", "支線補證據\n不得合併", "擋", .red, CGRect(x: 315, y: 494, width: 175, height: 60), .fail),
            node("supervisor-pass", "副審通過", "帶證據送主導\n附反例結論", "過", .green, CGRect(x: 595, y: 494, width: 175, height: 60), .pass),
            node("lead-fail", "主導駁回", "重派 loops\n修主線偏差", "擋", .red, CGRect(x: 315, y: 618, width: 175, height: 60), .fail),
            node("lead-pass", "主導通過", "進入 Goal\n產出交付", "過", .green, CGRect(x: 595, y: 618, width: 175, height: 60), .pass)
        ]
    }

    private static func receiptNode(contract: TatwoWorkOSContractV1) -> [WorkOSPlanLoopsGoalNode] {
        let text = contract.sandboxPolicy.required ? "沙盒 / 測試 / 截圖 / 回滾" : "差異 / 命令 / 截圖 / 清理"
        return [
            node("receipt-bank", "收據庫", "\(text)\n只入庫，不自動放行", "R", .teal, CGRect(x: 876, y: 504, width: 180, height: 78), .receipt)
        ]
    }

    private static func connectors(nodes: [WorkOSPlanLoopsGoalNode], contract: TatwoWorkOSContractV1) -> [WorkOSPlanLoopsGoalConnector] {
        let dict = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0.rect) })
        func r(_ id: String) -> CGRect { dict[id] ?? .zero }
        var result: [WorkOSPlanLoopsGoalConnector] = []

        result += [
            connector("main-task-plan", [right(r("task")), left(r("plan"))], .black, .cyan, .main, 2.4),
            connector("main-plan-loops", [right(r("plan")), left(r("loops"))], .black, .cyan, .main, 2.4),
            connector("main-loops-goal", [right(r("loops")), left(r("goal"))], .black, .cyan, .main, 2.4),
            connector("main-goal-done", [right(r("goal")), left(r("done"))], .green, .green, .main, 2.6)
        ]

        for id in branchBlueprints(contract: contract).map(\.id) {
            let branch = r(id)
            result.append(connector(
                "loops-to-\(id)",
                [bottom(r("loops")), CGPoint(x: r("loops").midX, y: 296), CGPoint(x: branch.midX, y: 296), top(branch)],
                .orange,
                .orange,
                .branch,
                2.1
            ))
            result.append(connector(
                "\(id)-to-review-bus",
                [bottom(branch), CGPoint(x: branch.midX, y: 452), CGPoint(x: 552, y: 452)],
                .yellow,
                .yellow,
                .branch,
                1.75
            ))
        }

        result += [
            connector("bus-to-supervisor-fail", [CGPoint(x: 552, y: 452), CGPoint(x: 552, y: 480), CGPoint(x: r("supervisor-fail").midX, y: 480), top(r("supervisor-fail"))], .red, .red, .fail, 1.9),
            connector("bus-to-supervisor-pass", [CGPoint(x: 552, y: 452), CGPoint(x: 552, y: 480), CGPoint(x: r("supervisor-pass").midX, y: 480), top(r("supervisor-pass"))], .green, .green, .pass, 2.0),
            connector("supervisor-fail-return", [left(r("supervisor-fail")), CGPoint(x: 246, y: r("supervisor-fail").midY), CGPoint(x: 246, y: 386), CGPoint(x: 300, y: 386)], .red, .red, .fail, 1.55),
            connector("supervisor-pass-to-lead-split", [bottom(r("supervisor-pass")), CGPoint(x: r("supervisor-pass").midX, y: 586), CGPoint(x: 552, y: 586), CGPoint(x: 552, y: 648)], .green, .green, .pass, 1.8),
            connector("lead-split-to-fail", [CGPoint(x: 552, y: 648), CGPoint(x: 552, y: r("lead-fail").midY), right(r("lead-fail"))], .red, .red, .fail, 1.8),
            connector("lead-split-to-pass", [CGPoint(x: 552, y: 648), CGPoint(x: 552, y: r("lead-pass").midY), left(r("lead-pass"))], .green, .green, .pass, 2.0),
            connector("lead-fail-return", [left(r("lead-fail")), CGPoint(x: 246, y: r("lead-fail").midY), CGPoint(x: 246, y: 296), CGPoint(x: r("loops").midX, y: 296), bottom(r("loops"))], .red, .red, .fail, 1.65),
            connector("lead-pass-to-goal", [right(r("lead-pass")), CGPoint(x: 1084, y: r("lead-pass").midY), CGPoint(x: 1084, y: 290), CGPoint(x: r("goal").midX, y: 290), bottom(r("goal"))], .green, .green, .pass, 2.2),
            connector("goal-to-receipts", [bottom(r("goal")), CGPoint(x: r("goal").midX, y: 292), CGPoint(x: r("receipt-bank").midX, y: 292), top(r("receipt-bank"))], .teal, .teal, .receipt, 1.55),
            connector("receipts-to-goal", [top(r("receipt-bank")), CGPoint(x: r("receipt-bank").midX, y: 286), CGPoint(x: r("goal").midX, y: 286), bottom(r("goal"))], .teal, .teal, .receipt, 1.35)
        ]

        return result
    }

    private struct BranchBlueprint {
        let id: String
        let title: String
        let subtitle: String
        let kicker: String
        let color: Color
    }

    private static func branchBlueprints(contract: TatwoWorkOSContractV1) -> [BranchBlueprint] {
        let scenario = scenarioKind(contract.scenario)
        let candidates: [BranchBlueprint]
        switch scenario {
        case "ui":
            candidates = [
                .init(id: "branch-visual", title: "主視覺支線", subtitle: "風格 / 留白 / 比例\n交回截圖證據", kicker: "UI", color: .blue),
                .init(id: "branch-code", title: "代碼歸納支線", subtitle: "元件 / 狀態 / 一致\n保留最小差異", kicker: "Code", color: .indigo),
                .init(id: "branch-ux", title: "交互驗收支線", subtitle: "點擊 / 捲動 / 斷點\n不可只看 build", kicker: "UX", color: .teal)
            ]
        case "research":
            candidates = [
                .init(id: "branch-source", title: "來源支線", subtitle: "官方 / 時間 / 引用\n標清楚來源等級", kicker: "查", color: .blue),
                .init(id: "branch-rebuttal", title: "反例支線", subtitle: "找相反證據\n不替主張護航", kicker: "反", color: .red),
                .init(id: "branch-ledger", title: "證據表支線", subtitle: "claim / status / gap\n缺口不能硬補", kicker: "證", color: .teal)
            ]
        case "trading":
            candidates = [
                .init(id: "branch-data", title: "消息支線", subtitle: "來源 / 行情 / 時間\n只讀", kicker: "News", color: .blue),
                .init(id: "branch-risk", title: "風控支線", subtitle: "資金 / 槓桿 / 禁區\n只讀", kicker: "Risk", color: .red),
                .init(id: "branch-against", title: "反方支線", subtitle: "失效條件 / 反例\n不產生下單訊號", kicker: "反", color: .purple)
            ]
        case "modeling":
            candidates = [
                .init(id: "branch-candidate", title: "候選支線", subtitle: "多路草案 / 選型\n先不定案", kicker: "候", color: .blue),
                .init(id: "branch-probe", title: "小測支線", subtitle: "樣本 / 成本 / 限制\n跑出可重複證據", kicker: "測", color: .teal),
                .init(id: "branch-compare", title: "比較支線", subtitle: "優缺 / 失敗條件\n寫明取捨", kicker: "比", color: .orange)
            ]
        case "daily":
            candidates = [
                .init(id: "branch-clarity", title: "需求收斂支線", subtitle: "抓重點 / 不加戲\n把問題變短", kicker: "收", color: .blue),
                .init(id: "branch-review", title: "副審支線", subtitle: "錯漏 / 語氣 / 結論\n擋掉爛答案", kicker: "審", color: .purple),
                .init(id: "branch-sub", title: "Sub 支線", subtitle: "雜事 / 候選 / 草稿\n交回不定案", kicker: "Sub", color: .teal)
            ]
        default:
            candidates = [
                .init(id: "branch-read", title: "讀碼支線", subtitle: "找入口 / 影響面\n不得猜路徑", kicker: "讀", color: .blue),
                .init(id: "branch-patch", title: "修補支線", subtitle: "最小 patch\n保留回滾", kicker: "修", color: .indigo),
                .init(id: "branch-test", title: "測試支線", subtitle: "build / test / smoke\n產出收據", kicker: "測", color: .teal)
            ]
        }

        switch contract.mode {
        case .s:
            return [candidates[0]]
        case .m:
            return Array(candidates.prefix(3))
        case .l:
            return Array(candidates.prefix(3))
        case .xl, .xxl:
            return Array(candidates.prefix(3))
        }
    }

    private static func branchRects(count: Int) -> [CGRect] {
        switch count {
        case 1:
            return [CGRect(x: 518, y: 356, width: 176, height: 62)]
        case 2:
            return [
                CGRect(x: 408, y: 356, width: 176, height: 62),
                CGRect(x: 628, y: 356, width: 176, height: 62)
            ]
        default:
            return [
                CGRect(x: 300, y: 356, width: 176, height: 62),
                CGRect(x: 518, y: 356, width: 176, height: 62),
                CGRect(x: 736, y: 356, width: 176, height: 62)
            ]
        }
    }

    private static func receiptTags(contract: TatwoWorkOSContractV1) -> [String] {
        var tags = ["contractID", "身份組", "副審", "測試/截圖"]
        if contract.sandboxPolicy.required { tags.append("沙盒") }
        if contract.sandboxPolicy.humanGateRequired { tags.append("人工 Gate") }
        if contract.receiptRequirements.contains(where: { $0.id.contains("rollback") }) { tags.append("回滾") }
        tags.append("cleanup")
        return tags
    }

    private static func modeSummary(contract: TatwoWorkOSContractV1) -> String {
        let scenario = scenarioLabel(contract.scenario)
        switch contract.mode {
        case .s: return "S / \(scenario)：主線直修，必要時小 loop，不開大隊"
        case .m: return "M / \(scenario)：主導定 plan，副審帶 loops，Goal 收斂"
        case .l: return "L / \(scenario)：單領域深 loop，加沙盒 / 回滾收據"
        case .xl, .xxl: return "XL / \(scenario)：主線監督，多支線自主搭建與驗證"
        }
    }

    private static func scenarioKind(_ raw: String) -> String {
        let value = raw.lowercased()
        if value.contains("ui") || value.contains("design") || value.contains("editing") { return "ui" }
        if value.contains("trading") { return "trading" }
        if value.contains("model") || value.contains("video") { return "modeling" }
        if value.contains("research") { return "research" }
        if value.contains("daily") { return "daily" }
        return "code"
    }

    private static func scenarioLabel(_ raw: String) -> String {
        switch scenarioKind(raw) {
        case "ui": return "UI"
        case "trading": return "交易"
        case "modeling": return "建模"
        case "research": return "研究"
        case "daily": return "通用"
        default: return "代碼"
        }
    }

    private static func node(
        _ id: String,
        _ title: String,
        _ subtitle: String,
        _ kicker: String,
        _ color: Color,
        _ rect: CGRect,
        _ kind: WorkOSPlanLoopsGoalNode.Kind
    ) -> WorkOSPlanLoopsGoalNode {
        WorkOSPlanLoopsGoalNode(id: id, title: title, subtitle: subtitle, kicker: kicker, color: color, rect: rect, kind: kind)
    }

    private static func connector(
        _ id: String,
        _ points: [CGPoint],
        _ baseColor: Color,
        _ flowColor: Color,
        _ style: WorkOSPlanLoopsGoalConnector.Style,
        _ width: CGFloat
    ) -> WorkOSPlanLoopsGoalConnector {
        WorkOSPlanLoopsGoalConnector(id: id, points: orthogonalized(points).filterAdjacentDuplicates(), baseColor: baseColor, flowColor: flowColor, style: style, width: width)
    }

    private static func orthogonalized(_ points: [CGPoint]) -> [CGPoint] {
        guard let first = points.first else { return [] }
        var result = [first]
        for next in points.dropFirst() {
            guard let current = result.last else { continue }
            let dx = abs(next.x - current.x)
            let dy = abs(next.y - current.y)
            if dx < 0.5 || dy < 0.5 {
                result.append(next)
            } else if dx >= dy {
                result.append(CGPoint(x: next.x, y: current.y))
                result.append(next)
            } else {
                result.append(CGPoint(x: current.x, y: next.y))
                result.append(next)
            }
        }
        return result
    }

    private static func left(_ rect: CGRect) -> CGPoint { CGPoint(x: rect.minX, y: rect.midY) }
    private static func right(_ rect: CGRect) -> CGPoint { CGPoint(x: rect.maxX, y: rect.midY) }
    private static func top(_ rect: CGRect) -> CGPoint { CGPoint(x: rect.midX, y: rect.minY) }
    private static func bottom(_ rect: CGRect) -> CGPoint { CGPoint(x: rect.midX, y: rect.maxY) }
}

enum WorkOSFlowTemplateFactory {
    static func make(contract: TatwoWorkOSContractV1) -> WorkOSFlowTemplate {
        switch contract.mode {
        case .s: return sTemplate(contract)
        case .m: return mTemplate(contract)
        case .l: return lTemplate(contract)
        case .xl, .xxl: return xlTemplate(contract)
        }
    }

    private static func sTemplate(_ contract: TatwoWorkOSContractV1) -> WorkOSFlowTemplate {
        let scenario = scenarioText(contract)
        let nodes = [
            node("goal", "目標", "單點症狀\n不展開", .mint, 0.04, 0.10),
            node("contract", "OS 合約", "S / \(scenario)\n0 sub", .green, 0.29, 0.10),
            node("lead", "主導", "同一宿主\n直修", .cyan, 0.54, 0.10),
            node("stop", "停止線", "小修邊界\n不升級", .orange, 0.79, 0.10),
            node("inspect", "查證", "檔案 / log\n本機證據", .blue, 0.16, 0.43),
            node("action", "微調", "最小改動\n或回答", .indigo, 0.41, 0.43),
            node("receipt", "收據", "差異 / 煙測\n截圖選用", .teal, 0.66, 0.43),
            node("retry", "回查", "未通過\n不硬過", .red, 0.29, 0.74),
            node("close", "結案", "通過後\n回覆", .orange, 0.58, 0.74),
        ]
        let edges = [
            edge("s-a", "goal", "contract", .mint),
            edge("s-b", "contract", "lead", .green),
            edge("s-c", "lead", "stop", .cyan),
            edge("s-d", "lead", "inspect", .blue, via: [CGPoint(x: 0.64, y: 0.34), CGPoint(x: 0.26, y: 0.34)]),
            edge("s-e", "inspect", "action", .blue),
            edge("s-f", "action", "receipt", .indigo),
            edge("s-g", "receipt", "close", .teal),
            edge("s-h", "receipt", "retry", .red, via: [CGPoint(x: 0.76, y: 0.66), CGPoint(x: 0.39, y: 0.66)], feedback: true),
            edge("s-i", "retry", "inspect", .red, via: [CGPoint(x: 0.39, y: 0.37), CGPoint(x: 0.26, y: 0.37)], feedback: true),
        ]
        return WorkOSFlowTemplate(
            id: "S-\(contract.scenario)-direct-evidence",
            nodes: nodes,
            edges: edges,
            lanes: laneSet([
                ("os", "OS 入口", "先建 contract，限制在小修", .green, 0.04, 0.04, 0.92, 0.25),
                ("work", "本機小回圈", "查證 → 微調 → 收據", .blue, 0.04, 0.36, 0.92, 0.25),
                ("gate", "驗收 / 回查", "不通過就回查，不自評硬過", .orange, 0.04, 0.68, 0.92, 0.25),
            ])
        )
    }

    static func surfaceSummary(contract: TatwoWorkOSContractV1) -> String {
        switch contract.mode {
        case .s:
            return "S 小修：主線直接修，附本機查證收據"
        case .m:
            switch scenarioKind(contract) {
            case "ui": return "M 協作 · UI：改視覺附截圖，交副審驗"
            case "trading": return "M 協作 · 交易：只讀分析禁下單，副審把關"
            case "research": return "M 協作 · 研究：找來源與反例，證據說話"
            case "modeling": return "M 協作 · 建模：多候選驗證後收斂"
            case "daily": return "M 協作：小隊分工，收據齊了才回報"
            default: return "M 協作 · 代碼：圈範圍改動，測試綠交副審"
            }
        case .l:
            return "L 專案：深耕單領域，沙盒先行可回滾"
        case .xl, .xxl:
            return "XL 重型：多線並進，沙盒與人工雙關卡"
        }
    }

    private static func mTemplate(_ contract: TatwoWorkOSContractV1) -> WorkOSFlowTemplate {
        switch scenarioKind(contract) {
        case "ui": return mUITemplate(contract)
        case "trading": return mTradingTemplate(contract)
        case "research": return mResearchTemplate(contract)
        case "modeling": return mModelingTemplate(contract)
        case "daily": return mDailyTemplate(contract)
        default: return mCodingTemplate(contract)
        }
    }

    private static func mUITemplate(_ contract: TatwoWorkOSContractV1) -> WorkOSFlowTemplate {
        let nodes = [
            node("ui-goal", "需求", "畫面目標\n使用者口徑", .mint, 0.04, 0.095),
            node("ui-contract", "OS 合約", "M / UI\n≤4 幫手", .green, 0.29, 0.095),
            node("ui-roles", "身份組", "主視覺\n代碼歸納", .purple, 0.54, 0.095),
            node("ui-main", "主線", "收斂\n不偏題", .cyan, 0.79, 0.095),
            node("ui-visual", "視覺 loop", "比例 / 留白\n風格一致", .blue, 0.04, 0.390),
            node("ui-code", "代碼整理", "元件 / 狀態\n避免硬湊", .indigo, 0.29, 0.390),
            node("ui-shot", "截圖", "實畫面\n不是自評", .teal, 0.54, 0.390),
            node("ui-interact", "交互驗收", "點擊 / 捲動\n可理解", .orange, 0.79, 0.390),
            node("ui-fix", "微修", "小批修正\n保留差異", .pink, 0.04, 0.705),
            node("ui-review", "副審", "找醜點\n找漏改", .purple, 0.29, 0.705),
            node("ui-receipt", "收據", "截圖 + 煙測\n才能過", .teal, 0.54, 0.705),
            node("ui-close", "交付", "通過後\n回覆", .orange, 0.79, 0.705),
        ]
        let edges = [
            edge("mui-a", "ui-goal", "ui-contract", .mint),
            edge("mui-b", "ui-contract", "ui-roles", .green),
            edge("mui-c", "ui-roles", "ui-main", .purple),
            edge("mui-d", "ui-main", "ui-visual", .cyan, via: [CGPoint(x: 0.89, y: 0.300), CGPoint(x: 0.14, y: 0.300)]),
            edge("mui-e", "ui-visual", "ui-code", .blue),
            edge("mui-f", "ui-code", "ui-shot", .indigo),
            edge("mui-g", "ui-shot", "ui-interact", .teal),
            edge("mui-h", "ui-interact", "ui-review", .orange, via: [CGPoint(x: 0.89, y: 0.605), CGPoint(x: 0.39, y: 0.605)]),
            edge("mui-i", "ui-review", "ui-receipt", .purple),
            edge("mui-j", "ui-receipt", "ui-close", .teal),
            edge("mui-k", "ui-review", "ui-fix", .red, feedback: true),
            edge("mui-l", "ui-fix", "ui-visual", .red, feedback: true),
        ]
        return WorkOSFlowTemplate(
            id: "M-ui-visual-interaction",
            nodes: nodes,
            edges: edges,
            lanes: laneSet([
                ("os", "OS 約束", "先鎖需求、身份、停止線", .green, 0.04, 0.03, 0.92, 0.22),
                ("work", "UI 協作 loop", "視覺、代碼、截圖、交互分開驗", .blue, 0.04, 0.315, 0.92, 0.255),
                ("gate", "副審 / 收據", "沒有畫面證據就不通過", .orange, 0.04, 0.625, 0.92, 0.315),
            ])
        )
    }

    private static func mCodingTemplate(_ contract: TatwoWorkOSContractV1) -> WorkOSFlowTemplate {
        let nodes = [
            node("code-scope", "範圍", "入口 / 檔案\n改動邊界", .mint, 0.04, 0.095),
            node("code-contract", "OS 合約", "M / 代碼\n≤4 幫手", .green, 0.29, 0.095),
            node("code-roles", "身份組", "主導 / 副審\n驗收分離", .purple, 0.54, 0.095),
            node("code-main", "主線", "拆任務\n控風險", .cyan, 0.79, 0.095),
            node("code-read", "讀碼", "找入口\n看影響", .blue, 0.04, 0.390),
            node("code-patch", "修補", "小批差異\n不偷改", .indigo, 0.29, 0.390),
            node("code-test", "測試", "建置 / lint\n單測煙測", .teal, 0.54, 0.390),
            node("code-review", "審稿", "漏測 / 破壞\n反例", .purple, 0.79, 0.390),
            node("code-fix", "回修", "失敗點\n最小修", .red, 0.04, 0.705),
            node("code-receipt", "收據", "差異+測試\n命令輸出", .teal, 0.29, 0.705),
            node("code-merge", "合併", "主線收口\n可回滾", .orange, 0.54, 0.705),
            node("code-close", "交付", "說清\n未驗項", .orange, 0.79, 0.705),
        ]
        let edges = [
            edge("mcode-a", "code-scope", "code-contract", .mint),
            edge("mcode-b", "code-contract", "code-roles", .green),
            edge("mcode-c", "code-roles", "code-main", .purple),
            edge("mcode-d", "code-main", "code-read", .cyan, via: [CGPoint(x: 0.89, y: 0.300), CGPoint(x: 0.14, y: 0.300)]),
            edge("mcode-e", "code-read", "code-patch", .blue),
            edge("mcode-f", "code-patch", "code-test", .indigo),
            edge("mcode-g", "code-test", "code-review", .teal),
            edge("mcode-h", "code-review", "code-receipt", .purple, via: [CGPoint(x: 0.89, y: 0.605), CGPoint(x: 0.39, y: 0.605)]),
            edge("mcode-i", "code-receipt", "code-merge", .teal),
            edge("mcode-j", "code-merge", "code-close", .orange),
            edge("mcode-k", "code-review", "code-fix", .red, via: [CGPoint(x: 0.89, y: 0.925), CGPoint(x: 0.14, y: 0.925)], feedback: true),
            edge("mcode-l", "code-fix", "code-patch", .red, feedback: true),
        ]
        return WorkOSFlowTemplate(
            id: "M-coding-diff-test-review",
            nodes: nodes,
            edges: edges,
            lanes: laneSet([
                ("os", "OS 約束", "先定範圍與身份，不讓 patch 亂長", .green, 0.04, 0.03, 0.92, 0.22),
                ("work", "代碼 loop", "讀碼、修補、測試、副審一條線", .blue, 0.04, 0.315, 0.92, 0.255),
                ("gate", "收據 / 回修", "命令輸出與差異才能證明", .orange, 0.04, 0.625, 0.92, 0.315),
            ])
        )
    }

    private static func mResearchTemplate(_ contract: TatwoWorkOSContractV1) -> WorkOSFlowTemplate {
        let nodes = [
            node("research-question", "問題", "要證明什麼\n先切清楚", .mint, 0.04, 0.095),
            node("research-contract", "OS 合約", "M / 研究\n≤4 幫手", .green, 0.29, 0.095),
            node("research-roles", "身份組", "消息 / 反方\n結論分離", .purple, 0.54, 0.095),
            node("research-main", "主線", "問題樹\n收斂", .cyan, 0.79, 0.095),
            node("research-source", "來源", "新消息\n標時間", .blue, 0.04, 0.390),
            node("research-claim", "主張", "整理 claim\n不先相信", .indigo, 0.29, 0.390),
            node("research-rebuttal", "反例", "找相反證據\n挑戰結論", .red, 0.54, 0.390),
            node("research-ledger", "證據表", "來源 / 狀態\n可信度", .teal, 0.79, 0.390),
            node("research-gap", "缺口", "未證明\n待查", .orange, 0.04, 0.705),
            node("research-review", "副審", "來源偏誤\n邏輯漏洞", .purple, 0.29, 0.705),
            node("research-result", "結論", "可用 / 假設\n分開", .teal, 0.54, 0.705),
            node("research-close", "下一步", "追問或\n收口", .orange, 0.79, 0.705),
        ]
        let edges = [
            edge("mres-a", "research-question", "research-contract", .mint),
            edge("mres-b", "research-contract", "research-roles", .green),
            edge("mres-c", "research-roles", "research-main", .purple),
            edge("mres-d", "research-main", "research-source", .cyan, via: [CGPoint(x: 0.89, y: 0.300), CGPoint(x: 0.14, y: 0.300)]),
            edge("mres-e", "research-source", "research-claim", .blue),
            edge("mres-f", "research-claim", "research-rebuttal", .indigo),
            edge("mres-g", "research-rebuttal", "research-ledger", .red),
            edge("mres-h", "research-ledger", "research-review", .teal, via: [CGPoint(x: 0.89, y: 0.605), CGPoint(x: 0.39, y: 0.605)]),
            edge("mres-i", "research-review", "research-result", .purple),
            edge("mres-j", "research-result", "research-close", .teal),
            edge("mres-k", "research-review", "research-gap", .orange, feedback: true),
            edge("mres-l", "research-gap", "research-source", .red, via: [CGPoint(x: 0.14, y: 0.300)], feedback: true),
        ]
        return WorkOSFlowTemplate(
            id: "M-research-source-rebuttal-ledger",
            nodes: nodes,
            edges: edges,
            lanes: laneSet([
                ("os", "OS 約束", "問題、身份、來源規則先固定", .green, 0.04, 0.03, 0.92, 0.22),
                ("work", "研究 loop", "來源、主張、反例、證據表", .blue, 0.04, 0.315, 0.92, 0.255),
                ("gate", "副審 / 缺口", "不確定就標假設，不裝成結論", .orange, 0.04, 0.625, 0.92, 0.315),
            ])
        )
    }

    private static func mTradingTemplate(_ contract: TatwoWorkOSContractV1) -> WorkOSFlowTemplate {
        let nodes = [
            node("trade-goal", "只讀目標", "不下單\n不改風控", .mint, 0.04, 0.095),
            node("trade-contract", "OS 合約", "M / 交易\n只讀", .green, 0.29, 0.095),
            node("trade-roles", "身份組", "消息 / 風控\n驗收分離", .purple, 0.54, 0.095),
            node("trade-main", "主線", "研究問題\n禁止越權", .cyan, 0.79, 0.095),
            node("trade-data", "資料", "行情 / 新聞\n標來源", .blue, 0.04, 0.390),
            node("trade-thesis", "觀點", "假設\n不當訊號", .indigo, 0.29, 0.390),
            node("trade-risk", "風控", "資金 / 槓桿\n不得操作", .red, 0.54, 0.390),
            node("trade-block", "禁止動作", "order / key\nlive 變更", .orange, 0.79, 0.390),
            node("trade-rebuttal", "反方", "找反例\n失效條件", .purple, 0.04, 0.705),
            node("trade-receipt", "收據", "來源 + 風險\n只讀證明", .teal, 0.29, 0.705),
            node("trade-review", "風險副審", "高風險\n擋下", .red, 0.54, 0.705),
            node("trade-close", "結論", "研究輸出\n非交易指令", .orange, 0.79, 0.705),
        ]
        let edges = [
            edge("mtrade-a", "trade-goal", "trade-contract", .mint),
            edge("mtrade-b", "trade-contract", "trade-roles", .green),
            edge("mtrade-c", "trade-roles", "trade-main", .purple),
            edge("mtrade-d", "trade-main", "trade-data", .cyan, via: [CGPoint(x: 0.89, y: 0.300), CGPoint(x: 0.14, y: 0.300)]),
            edge("mtrade-e", "trade-data", "trade-thesis", .blue),
            edge("mtrade-f", "trade-thesis", "trade-risk", .indigo),
            edge("mtrade-g", "trade-risk", "trade-block", .red),
            edge("mtrade-h", "trade-block", "trade-review", .orange, via: [CGPoint(x: 0.89, y: 0.605), CGPoint(x: 0.64, y: 0.605)]),
            edge("mtrade-i", "trade-review", "trade-receipt", .red),
            edge("mtrade-j", "trade-receipt", "trade-close", .teal, via: [CGPoint(x: 0.39, y: 0.925), CGPoint(x: 0.89, y: 0.925)]),
            edge("mtrade-k", "trade-review", "trade-rebuttal", .purple, via: [CGPoint(x: 0.64, y: 0.925), CGPoint(x: 0.14, y: 0.925)], feedback: true),
            edge("mtrade-l", "trade-rebuttal", "trade-data", .red, via: [CGPoint(x: 0.14, y: 0.300)], feedback: true),
        ]
        return WorkOSFlowTemplate(
            id: "M-trading-readonly-risk-gate",
            nodes: nodes,
            edges: edges,
            lanes: laneSet([
                ("os", "OS 約束", "交易情境預設只讀，禁止越權", .green, 0.04, 0.03, 0.92, 0.22),
                ("work", "研究 / 風控 loop", "資料、觀點、風控、禁止動作分開", .blue, 0.04, 0.315, 0.92, 0.255),
                ("gate", "風險副審", "任何下單與 live 變更都擋下", .orange, 0.04, 0.625, 0.92, 0.315),
            ])
        )
    }

    private static func mModelingTemplate(_ contract: TatwoWorkOSContractV1) -> WorkOSFlowTemplate {
        let nodes = [
            node("model-goal", "建模目標", "輸入 / 輸出\n評估標準", .mint, 0.04, 0.095),
            node("model-contract", "OS 合約", "M / 建模\n≤4 幫手", .green, 0.29, 0.095),
            node("model-roles", "身份組", "候選 / 驗收\n分離", .purple, 0.54, 0.095),
            node("model-main", "主線", "選型\n收斂", .cyan, 0.79, 0.095),
            node("model-candidate", "候選", "多路草案\n不先定案", .blue, 0.04, 0.390),
            node("model-constraint", "限制", "資料 / 成本\n環境", .indigo, 0.29, 0.390),
            node("model-probe", "小測", "最小樣本\n可重跑", .teal, 0.54, 0.390),
            node("model-compare", "比較", "分數 / 失敗\n條件", .orange, 0.79, 0.390),
            node("model-fix", "重選", "未過\n換路線", .red, 0.04, 0.705),
            node("model-review", "副審", "過擬合\n假設漏洞", .purple, 0.29, 0.705),
            node("model-receipt", "收據", "樣本 / 結果\n限制", .teal, 0.54, 0.705),
            node("model-close", "決策", "採用 / 暫緩\n下一測", .orange, 0.79, 0.705),
        ]
        let edges = [
            edge("mmodel-a", "model-goal", "model-contract", .mint),
            edge("mmodel-b", "model-contract", "model-roles", .green),
            edge("mmodel-c", "model-roles", "model-main", .purple),
            edge("mmodel-d", "model-main", "model-candidate", .cyan, via: [CGPoint(x: 0.89, y: 0.300), CGPoint(x: 0.14, y: 0.300)]),
            edge("mmodel-e", "model-candidate", "model-constraint", .blue),
            edge("mmodel-f", "model-constraint", "model-probe", .indigo),
            edge("mmodel-g", "model-probe", "model-compare", .teal),
            edge("mmodel-h", "model-compare", "model-review", .orange, via: [CGPoint(x: 0.89, y: 0.605), CGPoint(x: 0.39, y: 0.605)]),
            edge("mmodel-i", "model-review", "model-receipt", .purple),
            edge("mmodel-j", "model-receipt", "model-close", .teal),
            edge("mmodel-k", "model-review", "model-fix", .red, feedback: true),
            edge("mmodel-l", "model-fix", "model-candidate", .red, via: [CGPoint(x: 0.14, y: 0.300)], feedback: true),
        ]
        return WorkOSFlowTemplate(
            id: "M-modeling-candidate-probe-review",
            nodes: nodes,
            edges: edges,
            lanes: laneSet([
                ("os", "OS 約束", "先定目標、限制與評估標準", .green, 0.04, 0.03, 0.92, 0.22),
                ("work", "建模 loop", "候選、限制、小測、比較", .blue, 0.04, 0.315, 0.92, 0.255),
                ("gate", "副審 / 收據", "收樣本與限制，不用模型自評", .orange, 0.04, 0.625, 0.92, 0.315),
            ])
        )
    }

    private static func mDailyTemplate(_ contract: TatwoWorkOSContractV1) -> WorkOSFlowTemplate {
        let nodes = [
            node("daily-goal", "需求", "輕量整理\n不開大隊", .mint, 0.04, 0.095),
            node("daily-contract", "OS 合約", "M / 通用\n小協作", .green, 0.29, 0.095),
            node("daily-roles", "身份組", "主導\n副審選用", .purple, 0.54, 0.095),
            node("daily-main", "主線", "保持簡潔\n不擴張", .cyan, 0.79, 0.095),
            node("daily-draft", "草稿", "整理 / 候選\n快速", .blue, 0.04, 0.390),
            node("daily-check", "檢查", "錯漏\n語氣", .indigo, 0.29, 0.390),
            node("daily-receipt", "收據", "依任務\n最小證據", .teal, 0.54, 0.390),
            node("daily-answer", "回答", "直給\n可追問", .orange, 0.79, 0.390),
            node("daily-retry", "修正", "不清楚\n回問", .red, 0.29, 0.705),
            node("daily-close", "收口", "完成\n不加戲", .orange, 0.58, 0.705),
        ]
        let edges = [
            edge("mdaily-a", "daily-goal", "daily-contract", .mint),
            edge("mdaily-b", "daily-contract", "daily-roles", .green),
            edge("mdaily-c", "daily-roles", "daily-main", .purple),
            edge("mdaily-d", "daily-main", "daily-draft", .cyan, via: [CGPoint(x: 0.89, y: 0.300), CGPoint(x: 0.14, y: 0.300)]),
            edge("mdaily-e", "daily-draft", "daily-check", .blue),
            edge("mdaily-f", "daily-check", "daily-receipt", .indigo),
            edge("mdaily-g", "daily-receipt", "daily-answer", .teal),
            edge("mdaily-h", "daily-answer", "daily-close", .orange),
            edge("mdaily-i", "daily-check", "daily-retry", .red, feedback: true),
            edge("mdaily-j", "daily-retry", "daily-check", .red, feedback: true),
        ]
        return WorkOSFlowTemplate(
            id: "M-daily-compact-review",
            nodes: nodes,
            edges: edges,
            lanes: laneSet([
                ("os", "OS 約束", "小協作但不擴張", .green, 0.04, 0.03, 0.92, 0.22),
                ("work", "輕量 loop", "草稿、檢查、收據、回答", .blue, 0.04, 0.315, 0.92, 0.255),
                ("gate", "修正 / 收口", "不清楚就回問，不亂補", .orange, 0.04, 0.625, 0.92, 0.315),
            ])
        )
    }

    private static func lTemplate(_ contract: TatwoWorkOSContractV1) -> WorkOSFlowTemplate {
        let domain = primaryDomain(contract)
        let script = scriptLabel(contract)
        let sandbox = contract.sandboxPolicy.required ? "臨時\n暫存" : "暫存\n預演"
        let nodes = [
            node("goal", "目標", "專案段落\n完工邊界", .mint, 0.04, 0.075),
            node("contract", "OS 合約", "L / \(scenarioText(contract))\n單領域", .green, 0.29, 0.075),
            node("identity", "身份組", "主導 + 監督\n驗收分離", .purple, 0.54, 0.075),
            node("mainline", "主線", "架構\n合併口徑", .cyan, 0.79, 0.075),
            node("domain", domain, "深 loop\n自主驗證", .blue, 0.04, 0.315),
            node("owner", "負責", ownerLabel(contract), .purple, 0.29, 0.315),
            node("script", script, "腳本 / CLI\n可重跑", .indigo, 0.54, 0.315),
            node("sandbox", "沙盒", sandbox, .brown, 0.79, 0.315),
            node("test", "測試", "建置 / lint\n煙測", .teal, 0.04, 0.555),
            node("review", "副審", "流程 bug\n反例", .purple, 0.29, 0.555),
            node("receipt", "收據包", "測試/審稿\n回滾", .teal, 0.54, 0.555),
            node("gate", "關卡", "通過才\n候選實裝", .orange, 0.79, 0.555),
            node("rollback", "回滾", "失敗復原\n不可跳過", .gray, 0.16, 0.805),
            node("next", "重派", "收斂後\n下一輪", .red, 0.42, 0.805),
            node("promote", "實裝", "證據足夠\n才放行", .orange, 0.68, 0.805),
        ]
        let edges = [
            edge("l-a", "goal", "contract", .mint),
            edge("l-b", "contract", "identity", .green),
            edge("l-c", "identity", "mainline", .purple),
            edge("l-d", "mainline", "domain", .cyan, via: [CGPoint(x: 0.89, y: 0.255), CGPoint(x: 0.14, y: 0.255)]),
            edge("l-e", "domain", "owner", .blue),
            edge("l-f", "owner", "script", .purple),
            edge("l-g", "script", "sandbox", .indigo),
            edge("l-h", "sandbox", "test", .brown, via: [CGPoint(x: 0.89, y: 0.505), CGPoint(x: 0.14, y: 0.505)]),
            edge("l-i", "test", "review", .teal),
            edge("l-j", "review", "receipt", .purple),
            edge("l-k", "receipt", "gate", .teal),
            edge("l-l", "gate", "promote", .orange),
            edge("l-m", "gate", "rollback", .red, via: [CGPoint(x: 0.89, y: 0.750), CGPoint(x: 0.26, y: 0.750)], feedback: true),
            edge("l-n", "rollback", "next", .red, feedback: true),
            edge("l-o", "next", "mainline", .red, via: [CGPoint(x: 0.52, y: 0.255), CGPoint(x: 0.89, y: 0.255)], feedback: true),
        ]
        return WorkOSFlowTemplate(
            id: "L-\(contract.scenario)-deep-domain",
            nodes: nodes,
            edges: edges,
            lanes: laneSet([
                ("os", "OS 入口", "專案段落先定義，不讓模型自由擴張", .green, 0.04, 0.020, 0.92, 0.215),
                ("domain", "單領域深 loop", "領域 owner 可自主做，但必須回主線", .blue, 0.04, 0.260, 0.92, 0.215),
                ("verify", "沙盒 / 收據", "測試、截圖、審稿、回滾都是收據", .teal, 0.04, 0.500, 0.92, 0.215),
                ("decision", "關卡 / 回滾", "通過才實裝；不通過就回滾", .orange, 0.04, 0.740, 0.92, 0.225),
            ])
        )
    }

    private static func xlTemplate(_ contract: TatwoWorkOSContractV1) -> WorkOSFlowTemplate {
        let domainTitles = paddedDomainTitles(contract, count: 3)
        let domainBodies = paddedDomainBodies(contract, count: 3)
        let nodes = [
            node("goal", "目標", "主線任務\n多區塊", .mint, 0.03, 0.090, width: 0.155),
            node("contract", "OS 合約", "XL / \(scenarioText(contract))\n合約ID", .green, 0.23, 0.090, width: 0.155),
            node("identity", "身份組", "主/監/顧\nsub/驗收", .purple, 0.43, 0.090, width: 0.155),
            node("mainline", "主線監督", "控各 loop\n不偏航", .cyan, 0.63, 0.090, width: 0.155),
            node("stop", "停止線", "預算/輪次\n人工關卡", .orange, 0.805, 0.090, width: 0.155),
            node("domain0", domainTitles[0], domainBodies[0], .blue, 0.03, 0.345, width: 0.155),
            node("domain1", domainTitles[1], domainBodies[1], .indigo, 0.23, 0.345, width: 0.155),
            node("domain2", domainTitles[2], domainBodies[2], .teal, 0.43, 0.345, width: 0.155),
            node("hub", "領域 Hub", "多 loop\n回主線", .cyan, 0.63, 0.345, width: 0.155),
            node("receipts", "收據池", "測試/審稿\n截圖/回滾", .teal, 0.805, 0.345, width: 0.155),
            node("tools", "工具原則", "技能 / MCP\nCLI / 瀏覽器", .indigo, 0.03, 0.585, width: 0.155),
            node("scripts", "腳本層", "JS / Swift\n可重跑", .pink, 0.23, 0.585, width: 0.155),
            node("sandbox", "沙盒", sandboxLabel(contract), .brown, 0.43, 0.585, width: 0.155),
            node("verify", "驗證矩陣", "煙測 / 差異\n視覺證據", .teal, 0.63, 0.585, width: 0.155),
            node("gate", "關卡收口", "證據足夠\n才候選", .orange, 0.805, 0.585, width: 0.155),
            node("supervisor", "監督", "抽查 loops\n抓偏航", .purple, 0.03, 0.825, width: 0.155),
            node("decision", "收據判定", "缺證據\n不候選", .teal, 0.23, 0.825, width: 0.155),
            node("human", "人工關卡", "你放行\n才升級", .orange, 0.43, 0.825, width: 0.155),
            node("promote", "待放行", "通過才升\n保留回溯", .orange, 0.63, 0.825, width: 0.155),
            node("rollback", "回滾", "未過重派\n不硬推", .red, 0.805, 0.825, width: 0.155),
        ]
        let edges = [
            edge("xl-a", "goal", "contract", .mint),
            edge("xl-b", "contract", "identity", .green),
            edge("xl-c", "identity", "mainline", .purple),
            edge("xl-d", "mainline", "stop", .cyan),
            edge("xl-e", "mainline", "hub", .cyan),
            edge("xl-f", "domain0", "hub", .blue, via: [CGPoint(x: 0.107, y: 0.525), CGPoint(x: 0.707, y: 0.525)]),
            edge("xl-g", "domain1", "hub", .indigo, via: [CGPoint(x: 0.307, y: 0.525), CGPoint(x: 0.707, y: 0.525)]),
            edge("xl-h", "domain2", "hub", .teal, via: [CGPoint(x: 0.507, y: 0.525), CGPoint(x: 0.707, y: 0.525)]),
            edge("xl-i", "hub", "receipts", .cyan),
            edge("xl-j", "domain0", "tools", .blue),
            edge("xl-k", "domain1", "scripts", .indigo),
            edge("xl-l", "domain2", "sandbox", .teal),
            edge("xl-m", "hub", "verify", .cyan),
            edge("xl-n", "receipts", "gate", .teal),
            edge("xl-o", "tools", "scripts", .indigo),
            edge("xl-p", "scripts", "sandbox", .pink),
            edge("xl-q", "sandbox", "verify", .brown),
            edge("xl-r", "verify", "gate", .teal),
            edge("xl-s", "gate", "supervisor", .teal, via: [CGPoint(x: 0.890, y: 0.750), CGPoint(x: 0.105, y: 0.750)]),
            edge("xl-t", "supervisor", "decision", .purple),
            edge("xl-u", "decision", "human", .teal),
            edge("xl-v", "human", "promote", .orange),
            edge("xl-w", "human", "rollback", .red, via: [CGPoint(x: 0.515, y: 0.965), CGPoint(x: 0.890, y: 0.965)], feedback: true),
            edge("xl-x", "rollback", "supervisor", .red, via: [CGPoint(x: 0.890, y: 0.965), CGPoint(x: 0.105, y: 0.965)], feedback: true),
        ]
        return WorkOSFlowTemplate(
            id: "XL-\(contract.scenario)-mainline-domain-os",
            nodes: nodes,
            edges: edges,
            lanes: laneSet([
                ("os", "OS 約束層", "先有 goal + contract，所有 agent 才能行動", .green, 0.04, 0.025, 0.92, 0.220),
                ("domains", "主線底下的多領域 loops", "每個區塊可自主搭建，但必須回主線合併", .blue, 0.04, 0.285, 0.92, 0.205),
                ("runtime", "工具 / 沙盒 / 收據", "工具調用與環境驗證不可靠模型自評", .teal, 0.04, 0.530, 0.92, 0.205),
                ("gate", "監督 / 人工關卡 / 回滾", "不通過就回滾或重派；App 只讀不可直接放行", .orange, 0.04, 0.775, 0.92, 0.205),
            ])
        )
    }

    private static func node(_ id: String, _ title: String, _ body: String, _ color: Color, _ x: CGFloat, _ y: CGFloat, width: CGFloat = 0.20, height: CGFloat = 0.13) -> WorkOSFlowNode {
        WorkOSFlowNode(id: id, title: title, body: body, color: color, rect: CGRect(x: x, y: y, width: width, height: height))
    }

    private static func edge(
        _ id: String,
        _ from: String,
        _ to: String,
        _ color: Color,
        via: [CGPoint] = [],
        feedback: Bool = false
    ) -> WorkOSFlowEdge {
        WorkOSFlowEdge(id: id, from: from, to: to, via: via, color: color, style: feedback ? .feedback : .primary)
    }

    private static func laneSet(_ defs: [(String, String, String, Color, CGFloat, CGFloat, CGFloat, CGFloat)]) -> [WorkOSFlowLane] {
        defs.map { id, title, subtitle, color, x, y, w, h in
            WorkOSFlowLane(id: id, title: title, subtitle: subtitle, color: color, rect: CGRect(x: x, y: y, width: w, height: h))
        }
    }

    private static func scenarioText(_ contract: TatwoWorkOSContractV1) -> String {
        switch contract.scenario {
        case "ui-ux", "design", "editing": return "UI"
        case "trading-risk", "trading": return "交易"
        case "modeling", "video-research": return "建模"
        case "research": return "研究"
        case "daily": return "通用"
        default: return "寫代碼"
        }
    }

    private static func scenarioKind(_ contract: TatwoWorkOSContractV1) -> String {
        switch contract.scenario {
        case "ui-ux", "design", "editing": return "ui"
        case "trading-risk", "trading": return "trading"
        case "modeling", "video-research": return "modeling"
        case "research": return "research"
        case "daily": return "daily"
        default: return "coding"
        }
    }

    private static func primaryDomain(_ contract: TatwoWorkOSContractV1) -> String {
        if let first = contract.domainLoops.first {
            return first.domain.plainName.replacingOccurrences(of: " / ", with: "/")
        }
        switch scenarioKind(contract) {
        case "ui": return "UI loop"
        case "trading": return "Risk loop"
        case "modeling": return "Model loop"
        case "research": return "Research loop"
        default: return "Code loop"
        }
    }

    private static func scenarioFocusLabel(_ contract: TatwoWorkOSContractV1) -> String {
        switch scenarioKind(contract) {
        case "ui": return "視覺/互動"
        case "trading": return "風控研究"
        case "research": return "來源反例"
        case "modeling": return "模型候選"
        default: return "代碼段落"
        }
    }

    private static func reviewerLabel(_ contract: TatwoWorkOSContractV1) -> String {
        switch scenarioKind(contract) {
        case "ui": return "互動驗收"
        case "trading": return "風險副審"
        case "research": return "來源副審"
        default: return "Reviewer"
        }
    }

    private static func evidenceLabel(_ contract: TatwoWorkOSContractV1) -> String {
        switch scenarioKind(contract) {
        case "ui": return "截圖/互動"
        case "trading": return "只讀/風控"
        case "research": return "來源/反例"
        default: return "測試/差異"
        }
    }

    private static func toolHint(_ contract: TatwoWorkOSContractV1) -> String {
        switch scenarioKind(contract) {
        case "ui": return "截圖\nUI 煙測"
        case "trading": return "只讀\n風控檢查"
        case "research": return "web/source\n引用"
        default: return "測試\n差異"
        }
    }

    private static func scriptLabel(_ contract: TatwoWorkOSContractV1) -> String {
        switch scenarioKind(contract) {
        case "ui": return "截圖腳本"
        case "trading": return "風控腳本"
        case "research": return "來源抽查"
        case "modeling": return "模型驗證"
        default: return "JS 腳本"
        }
    }

    private static func ownerLabel(_ contract: TatwoWorkOSContractV1) -> String {
        if let first = contract.domainLoops.first { return "\(first.ownerIdentity.chineseName)\n\(first.autonomyLevel)" }
        return "主導\n受主線約束"
    }

    private static func sandboxLabel(_ contract: TatwoWorkOSContractV1) -> String {
        if contract.sandboxPolicy.required && contract.sandboxPolicy.humanGateRequired { return "必須沙盒\n人工關卡" }
        if contract.sandboxPolicy.required { return "必須沙盒\n暫存" }
        return "暫存\n預演"
    }

    private static func paddedDomainTitles(_ contract: TatwoWorkOSContractV1, count: Int) -> [String] {
        let titles = contract.domainLoops.prefix(count).map { $0.domain.plainName.replacingOccurrences(of: " / ", with: "/") }
        let fallback = ["UI/UX", "代碼", "環境", "研究", "除錯"]
        return Array((titles + fallback).prefix(count))
    }

    private static func paddedDomainBodies(_ contract: TatwoWorkOSContractV1, count: Int) -> [String] {
        let bodies = contract.domainLoops.prefix(count).map { loop -> String in
            let tool = loop.allowedTools.first ?? loop.sandboxType.rawValue
            return "\(loop.ownerIdentity.chineseName)\n\(tool)"
        }
        let fallback = ["sub\n可替換", "驗收\n可重跑", "ops\n沙盒", "消息\n來源"]
        return Array((bodies + fallback).prefix(count))
    }
}
