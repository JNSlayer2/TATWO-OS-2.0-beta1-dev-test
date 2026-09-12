// 2.0 新畫面（不是照搬）：「OS」頁＝整個系統的架構圖，取代 1.0 照搬的 Ultra 手冊頁。
// 使用者 2026-09-05：這頁跟設定／文件要是同一個理解，讓他可視化回憶系統架構；不要註解、不要 1.0 名詞。
import SwiftUI

struct OSOverviewPage: View {
    @ObservedObject var model: ChatPageModel
    /// 點方塊要開設定頁的哪一分頁（由外面接到設定視窗）
    var openSettings: (String) -> Void = { _ in }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("TATWO OS")
                        .font(.title2.bold())
                    Text("所有 AI 引擎的上游。規矩由 OS 統一發，引擎只是肌肉；接新引擎不用重設。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)], spacing: 14) {
                    block(symbol: "point.3.connected.trianglepath.dotted", title: "上游",
                          lines: upstreamLines, lamp: upstreamLamp, action: "os")
                    block(symbol: "person.3", title: "身份組",
                          lines: ["你＝主人", "主導＝這條對話的引擎", "sub＝被派出去的引擎", "副審＝另一家看 diff", "監工＝機器（活性、壓力、範圍）"],
                          lamp: .clear, action: "")
                    block(symbol: "arrow.right.circle", title: "流程",
                          lines: ["目標：一句話＋issue 卡", "討論：/plan 只講不動手", "派工：/plg 開子對話與工作副本", "驗收：主導親自重跑、逐條對齊"],
                          lamp: .clear, action: "")
                    block(symbol: "brain", title: "記憶",
                          lines: ["GBrain（MCP）：raw → curated → truth", "蒸餾由 Claude 對話做，不是 App 自動", gbrainLine],
                          lamp: gbrainLamp, action: "")
                    block(symbol: "laptopcomputer.and.iphone", title: "設備",
                          lines: deviceLines, lamp: deviceLamp, action: "devices")
                    block(symbol: "wrench.and.screwdriver", title: "技能與工具",
                          lines: ["skillet.md：常用技能，$skillet 叫出", "技能根：~/Library/Application Support/tatwo2/skills", "MCP：瀏覽器橋、tatwo2_os、GitHub、GBrain（資訊卡勾）"],
                          lamp: .clear, action: "documents")
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("三家引擎")
                        .font(.headline)
                    ForEach(model.engineLogins) { st in
                        HStack(spacing: 8) {
                            Circle().fill(st.isLoggedIn ? Color.green : Color.secondary.opacity(0.35)).frame(width: 7, height: 7)
                            Text(Self.engineName(st.kind)).font(.subheadline)
                            Text(st.isLoggedIn ? (st.account ?? "已登入") : "未登入").font(.caption).foregroundStyle(.secondary)
                            if model.isEngineDisabled(st.kind) { Text("已禁用 API").font(.caption2).foregroundStyle(.red) }
                            Spacer()
                        }
                    }
                    Button("模型登入…") { openSettings("modelAccess") }
                        .buttonStyle(.link).controlSize(.small)
                }
                .padding(14)
                .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                Text("這頁是看的；要改規矩去 設定 › 文件，要接引擎去 設定 › OS。")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
            }
            .padding(24)
            .frame(maxWidth: 1040, alignment: .leading)
        }
        .onAppear { model.refreshUpstreamBindings(); model.refreshEngineLogins() }
    }

    // MARK: 方塊

    private func block(symbol: String, title: String, lines: [String], lamp: Color, action: String) -> some View {
        Button {
            if !action.isEmpty { openSettings(action) }
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: symbol).font(.system(size: 14, weight: .semibold)).foregroundStyle(.secondary)
                    Text(title).font(.headline)
                    Spacer()
                    if lamp != .clear { Circle().fill(lamp).frame(width: 8, height: 8) }
                }
                ForEach(lines, id: \.self) { line in
                    Text("・" + line)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
            .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: 動態內容

    private var upstreamLines: [String] {
        let b = model.upstreamBindings
        let bound = b.filter { $0.state == .bound }.count
        let stale = b.filter { $0.state == .stale }.count
        let unbound = b.filter { $0.state == .unbound }.count + b.filter { $0.state == .unreachable }.count
        return ["入口：" + model.osRootPath, "os.md（規矩）→ os-upstream.md（每條對話的一頁）→ 各家綁定段",
                b.isEmpty ? "還沒檢查" : "已接 \(bound)・有代差 \(stale)・沒接或讀不到 \(unbound)"]
    }
    private var upstreamLamp: Color {
        let b = model.upstreamBindings
        if b.isEmpty { return .clear }
        if b.contains(where: { $0.state == .stale }) { return .yellow }
        if b.allSatisfy({ $0.state == .bound }) { return .green }
        return .orange
    }
    private var gbrainLine: String {
        model.registeredPluginIDs.contains { $0.lowercased().contains("gbrain") } ? "已登記為 MCP" : "MCP 清單裡沒有 GBrain"
    }
    private var gbrainLamp: Color { model.registeredPluginIDs.contains { $0.lowercased().contains("gbrain") } ? .green : .clear }
    private var deviceLines: [String] {
        let online = model.remoteSidebarSections.filter(\.isOnline).count
        return ["這台：主機", "已配對 \(model.devices.count) 台・在線 \(online) 台", "並行：點遠端對話就在那台跑；右鍵併回／拉到"]
    }
    private var deviceLamp: Color { model.devices.isEmpty ? .clear : (model.remoteSidebarSections.contains(where: \.isOnline) ? .green : .orange) }

    private static func engineName(_ kind: ClaudeSidecar.Kind) -> String {
        switch kind { case .codex: "OpenAI"; case .claude: "Anthropic"; case .grok: "Grok" }
    }
}
