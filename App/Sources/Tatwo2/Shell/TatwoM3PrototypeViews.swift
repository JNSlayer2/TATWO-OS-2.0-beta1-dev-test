// 照搬自 Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac/TatwoM3PrototypeViews.swift；改動 7 行（原因：run A 照搬，僅移除舊水電 import／呼叫並接同名 Facade）
import SwiftUI
import Combine
import AppKit


extension TatwoPage {
    var stepNumber: Int {
        (TatwoPage.allCases.firstIndex(of: self) ?? 0) + 1
    }

    var shortTitle: String {
        switch self {
        case .chat: "對話"
        case .usage: "額度"
        case .modes: "模式"
        case .scenarios: "情境"
        case .compatibility: "特質"
        case .plugins: "外掛"
        case .devices: "設備"
        case .workflow: "工作流"
        }
    }
}

struct TatwoPageNavButton: View {
    @ObservedObject private var themeStore = TatwoThemeStore.shared
    let page: TatwoPage
    let isSelected: Bool

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: page.symbol)
                .symbolRenderingMode(.hierarchical)
                .font(.system(size: 13, weight: .bold))
            Text(page.shortTitle)
                .font(.system(size: 10, weight: .bold, design: .rounded))
        }
        .frame(width: 53, height: 43)
        // 工具列導覽格改跟主題：選中用 brandAccent(不用系統藍 accentColor)；底材走 tatwoAdaptiveMaterial(fable5 不漏玻璃)。
        .foregroundStyle(isSelected ? LiquidGlassTokens.brandAccent : Color.primary.opacity(0.78))
        .background {
            RoundedRectangle(cornerRadius: LiquidGlassTokens.radiusChip, style: LiquidGlassTokens.shapeStyle)
                .fill(isSelected ? LiquidGlassTokens.brandAccent.opacity(0.14) : Color.clear)
        }
        .tatwoAdaptiveMaterial(cornerRadius: LiquidGlassTokens.radiusChip)
        .overlay {
            RoundedRectangle(cornerRadius: LiquidGlassTokens.radiusChip, style: LiquidGlassTokens.shapeStyle)
                .strokeBorder(isSelected ? LiquidGlassTokens.brandAccent.opacity(0.45) : Color.clear, lineWidth: 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: LiquidGlassTokens.radiusChip, style: .continuous))
    }
}









struct ModelQuotaTopDeck: View {
    @ObservedObject private var themeStore = TatwoThemeStore.shared
    let providers: [UsageProviderStatus]
    @Environment(\.tatwoSurfaceKind) private var surface
    @State private var liveSnapshot: LiveQuotaDeckSnapshot
    @State private var isRefreshing = false
    @State private var expandedProviderIDs: Set<String> = []
    @State private var recentActivity: [TatwoRecentActivityRecord] = []
    @State private var isActivityRefreshing = false
    @State private var showActivity = false
    @State private var showEvents = false
    @State private var activitySourceAccess: ExternalVolumeAccess?
    @State private var activitySourceFailure: ExternalVolumeFailure?
    @State private var activitySourceLastGoodAt: Date?
    private let liveRefreshTimer = Timer.publish(every: 60, on: .main, in: .common).autoconnect()
    private let activityRefreshTimer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    init(providers: [UsageProviderStatus], initialLiveSnapshot: LiveQuotaDeckSnapshot? = nil) {
        self.providers = providers
        _liveSnapshot = State(initialValue: initialLiveSnapshot ?? .loading)
    }

    private var rows: [LiveQuotaDisplay] {
        providers.map { liveSnapshot.display(for: $0) }
    }

    private var providerEvents: [QuotaProviderEvent] {
        QuotaProviderEvent.events(from: rows)
    }

    private var providerGridColumns: [GridItem] {
        surface == .window
            ? [GridItem(.flexible(), spacing: 10)]
            : [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("額度用量")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                Spacer()
                Text(liveSnapshot.headerText)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Button {
                    Task {
                        await refreshLiveUsage(
                            allowExternalAccess: true,
                            refreshKind: .manual)
                    }
                } label: {
                    Label("live", systemImage: isRefreshing ? "arrow.triangle.2.circlepath" : "bolt.horizontal.circle")
                        .font(.caption2.weight(.black))
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .disabled(isRefreshing)
            }
            .padding(.horizontal, 4)

            LazyVGrid(columns: providerGridColumns, spacing: 10) {
                ForEach(rows) { row in
                    QuotaProviderCard(
                        row: row,
                        isExpanded: expandedProviderIDs.contains(row.id)
                    ) {
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.88)) {
                            if expandedProviderIDs.contains(row.id) {
                                expandedProviderIDs.remove(row.id)
                            } else {
                                expandedProviderIDs.insert(row.id)
                            }
                        }
                    }
                }
            }

            QuotaHubBottomFoldouts(
                activity: recentActivity,
                activitySourceAccess: activitySourceAccess,
                activitySourceFailure: activitySourceFailure,
                activitySourceLastGoodAt: activitySourceLastGoodAt,
                events: providerEvents,
                showActivity: $showActivity,
                showEvents: $showEvents
            )
        }
        .task {
            await refreshLiveUsageIfStale(maxAge: 10)
            await refreshRecentActivity()
        }
        .onAppear {
            Task { await refreshLiveUsageIfStale(maxAge: 10) }
            Task { await refreshRecentActivity() }
        }
        .onReceive(liveRefreshTimer) { _ in
            Task {
                await refreshLiveUsage(
                    allowExternalAccess: false,
                    refreshKind: .automatic)
            }
        }
        .onReceive(activityRefreshTimer) { _ in
            Task { await refreshRecentActivity() }
        }
    }

    @MainActor
    private func refreshLiveUsageIfStale(maxAge: TimeInterval) async {
        guard liveSnapshot.isStale(maxAge: maxAge) else { return }
        await refreshLiveUsage(
            allowExternalAccess: false,
            refreshKind: .automatic)
    }

    @MainActor
    private func refreshLiveUsage(
        allowExternalAccess: Bool,
        refreshKind: TatwoQuotaRefreshKind
    ) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        let providers = providers
        let snapshot = await Task.detached(priority: .utility) {
            await TatwoQuotaSnapshotCache.shared.load(
                providers: providers,
                refreshKind: refreshKind,
                allowExternalAccess: allowExternalAccess
            )
        }.value
        liveSnapshot = snapshot
        isRefreshing = false
    }

    @MainActor
    private func refreshRecentActivity() async {
        guard !isActivityRefreshing else { return }
        isActivityRefreshing = true
        let cutoff = Date().addingTimeInterval(-2 * 24 * 60 * 60)
        let result = await Task.detached(priority: .utility) {
            let runs = TatwoDispatchRegistry.default().allRuns(updatedSince: cutoff)
            var flattened: [TatwoRecentActivityRecord] = []
            for run in runs {
                var latest: [String: TatwoDispatchRecord] = [:]
                for record in run.records where record.updatedAt >= cutoff {
                    if let existing = latest[record.bindingID], existing.updatedAt >= record.updatedAt {
                        continue
                    }
                    latest[record.bindingID] = record
                }
                flattened.append(contentsOf: latest.values.map { TatwoRecentActivityRecord(dispatchRecord: $0) })
            }
            let codexActivity = TatwoCodexSessionActivitySource.loadRecentOutcome(
                since: cutoff,
                limit: 40,
                allowExternalVolumes: false
            )
            flattened.append(contentsOf: codexActivity.value ?? [])
            // 派工帳本：外部 sol sub(codex exec 並行 loops)寫進 ~/.tatwo-ultrawork/dispatch-ledger.jsonl，
            // 讓「動態」看得見我派出的並行 sub（使用者：動態要顯示當下的 sub，例如剛剛的多 sol 並行）。
            for e in TatwoDispatchLedgerReader().readEntries() where e.startedAt >= cutoff {
                flattened.append(TatwoRecentActivityRecord(
                    id: "ledger-\(e.id)",
                    modelID: e.model,
                    modelProvider: "gateway",
                    originator: e.label,
                    workdirSummary: e.note ?? "",
                    statusText: e.status.rawValue,
                    startedAt: e.startedAt,
                    updatedAt: e.endedAt ?? e.startedAt,
                    sourceKind: .dispatchRegistry,
                    modelConfidence: .providerOnly))
            }
            return (
                Array(flattened.sorted { $0.updatedAt > $1.updatedAt }.prefix(20)),
                codexActivity.access,
                codexActivity.failure,
                codexActivity.lastGoodAt
            )
        }.value
        recentActivity = result.0
        activitySourceAccess = result.1
        activitySourceFailure = result.2
        activitySourceLastGoodAt = result.3
        isActivityRefreshing = false
    }
}

struct QuotaProviderCard: View {
    @ObservedObject private var themeStore = TatwoThemeStore.shared
    let row: LiveQuotaDisplay
    let isExpanded: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 9) {
                    QuotaProviderLogo(row: row)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(row.displayName)
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .lineLimit(1)
                            .minimumScaleFactor(0.78)
                        Text(row.planLabel)
                            .font(.system(size: 9, weight: .black, design: .rounded))
                            .foregroundStyle(quotaBrandColors(row.id).first ?? .accentColor)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    HStack(alignment: .top, spacing: 7) {
                        QuotaStaticStatusDot(status: row.status)
                            .padding(.top, 6)
                            .accessibilityHidden(true)
                        VStack(alignment: .trailing, spacing: 2) {
                        Text(row.displayRemainingPercent == nil ? row.displayStatusText : percentText(row.displayRemainingPercent))
                            .font(.system(size: row.displayRemainingPercent == nil ? 12 : 18, weight: .black, design: .rounded))
                            .monospacedDigit()
                            .lineLimit(1)
                            .minimumScaleFactor(0.72)
                        Text(row.displayRemainingPercent == nil ? row.sourceBadge : "剩餘")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                        }
                    }
                }

                if row.hasLiveUsage {
                    SimpleQuotaBar(percent: row.displayRemainingPercent, height: 7, colors: quotaBrandColors(row.id))
                }

                Text(row.caption)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(isExpanded ? 2 : 1)
                    .minimumScaleFactor(0.82)

                if isExpanded {
                    QuotaProviderDetail(row: row)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                } else {
                    HStack(spacing: 5) {
                        Text(compactWindowText(row))
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.down")
                            .font(.caption2.weight(.black))
                    }
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 126, alignment: .topLeading)
            .background(cleanQuotaBackground)
            .overlay {
                if row.isPending {
                    QuotaSkeletonOverlay()
                        .allowsHitTesting(false)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(row.displayName) 額度卡")
        .accessibilityHint(isExpanded ? "收合詳細額度" : "展開 5 小時、1 週、重置與帳號方案")
    }
}


struct QuotaSkeletonOverlay: View {
    @ObservedObject private var themeStore = TatwoThemeStore.shared
    var body: some View {
        RoundedRectangle(cornerRadius: LiquidGlassTokens.radiusCard, style: LiquidGlassTokens.shapeStyle)
            .strokeBorder(Color.white.opacity(0.16), lineWidth: 1)
            .overlay(alignment: .bottomLeading) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(Color.accentColor.opacity(0.28))
                        .frame(width: 6, height: 6)
                    Text("即時骨架")
                        .font(.system(size: 9, weight: .black, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
            }
    }
}

struct QuotaStaticStatusDot: View {
    let status: InstallState

    private var color: Color {
        statusColor(status)
    }

    private var label: String {
        switch status {
        case .installed: return "live installed"
        case .missing: return "live missing"
        case .skipped: return "live skipped"
        case .unknown: return "live unknown"
        }
    }

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .overlay(Circle().strokeBorder(color.opacity(0.36), lineWidth: 3))
            .shadow(color: color.opacity(0.24), radius: 3, x: 0, y: 0)
            .accessibilityLabel(label)
    }
}

struct QuotaProviderLogo: View {
    let row: LiveQuotaDisplay

    // 中性淺玻璃 chip + 淡化 logo：保留 provider 辨識，去彩色漸變底/彩色陰影（使用者：ai 牌子頭貼破壞視覺風格）。
    var body: some View {
        ZStack {
            // 極光 P4 白平板收編：logo 底磚分主題——極光維持玻璃+白亮化，
            // fable5 改暖紙實底+暖邊（白磚在牛皮紙上是異物）。
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(
                    TatwoActivePalette.current.usesGlass
                        ? AnyShapeStyle(.ultraThinMaterial)
                        : AnyShapeStyle(TatwoActivePalette.current.surfaceFill))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.white.opacity(
                            TatwoActivePalette.current.usesGlass ? 0.28 : 0))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(
                            TatwoActivePalette.current.usesGlass
                                ? Color.white.opacity(0.14)
                                : TatwoActivePalette.current.surfaceBorder.opacity(0.75),
                            lineWidth: 1)
                )
            if let image = ProviderSVGIconLoader.image(for: row.id) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 17, height: 17)
                    .opacity(0.82)
            } else {
                Text(ProviderSVGIconLoader.fallbackInitials(for: row.id))
                    .font(.system(size: 10, weight: .black, design: .rounded))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 32, height: 32)
        .shadow(color: .black.opacity(0.06), radius: 4, x: 0, y: 2)
    }
}

enum ProviderSVGIconLoader {
    private static let fileNames: [String: String] = [
        "codex-gpt": "ProviderIcon-codex",
        "claude": "ProviderIcon-claude",
        "grok": "ProviderIcon-grok",
        "minimax": "ProviderIcon-minimax",
        "local-api": "ProviderIcon-ollama"
    ]

    static func image(for providerID: String) -> NSImage? {
        // 從安裝包讀圖示；缺檔時由呼叫端顯示縮寫，不依賴開發機的 build 目錄。
        guard let fileName = fileNames[providerID],
              let url = ProviderIconResources.url(for: fileName),
              let data = try? Data(contentsOf: url),
              let image = NSImage(data: data)
        else {
            return nil
        }
        image.isTemplate = false
        return image
    }

    static func fallbackInitials(for providerID: String) -> String {
        switch providerID {
        case "codex-gpt": "CX"
        case "claude": "CL"
        case "grok": "GK"
        case "minimax": "MM"
        case "local-api": "OL"
        default: "AI"
        }
    }
}

struct QuotaProviderDetail: View {
    let row: LiveQuotaDisplay

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Divider().opacity(0.55)
            if row.hasLiveUsage {
                QuotaWindowBar(title: "5小時", percent: row.primaryRemainingPercent, resetAt: row.primaryResetAt, rowID: row.id)
                QuotaWindowBar(title: "1週", percent: row.secondaryRemainingPercent, resetAt: row.secondaryResetAt, rowID: row.id)
                HStack(spacing: 6) {
                    Label(row.resetCreditsAvailable.map { "重置 \($0) 次" } ?? "重置次數未回傳", systemImage: "arrow.triangle.2.circlepath")
                    Spacer(minLength: 0)
                    Text(resetCreditExpiryText(row.resetCreditExpiryDates, fallback: row.resetCreditsExpiresAt))
                }
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            } else {
                QuotaIntegrationGuide(row: row)
            }
            VStack(alignment: .leading, spacing: 4) {
                detailLine("帳號 / 權限", row.permissionLabel)
                detailLine("方案", row.planLabel)
                detailLine("live 來源", row.sourceBadge)
            }
        }
    }

    private func detailLine(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 62, alignment: .leading)
            Text(value)
                .fontWeight(.bold)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Spacer(minLength: 0)
        }
        .font(.caption2)
    }
}

struct QuotaWindowBar: View {
    let title: String
    let percent: Int?
    let resetAt: Date?
    let rowID: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(title)
                    .font(.caption2.weight(.black))
                Spacer()
                Text(percentText(expired ? nil : percent))
                    .font(.caption2.weight(.black))
                    .monospacedDigit()
                Text(expired ? expiredResetText(resetAt) : resetText(resetAt))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }
            if let livePercent = expired ? nil : percent {
                SimpleQuotaBar(percent: livePercent, height: 5, colors: quotaBrandColors(rowID))
            }
        }
    }

    private var expired: Bool {
        resetAt.map { $0 <= Date() } ?? false
    }
}

struct QuotaIntegrationGuide: View {
    let row: LiveQuotaDisplay

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "cable.connector")
                .font(.caption.weight(.bold))
                .foregroundStyle(quotaBrandColors(row.id).first ?? .accentColor)
            VStack(alignment: .leading, spacing: 3) {
                Text("接入引導")
                    .font(.caption2.weight(.black))
                Text(integrationGuideText(row.id))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(9)
        // 極光 P4 白平板收編：接入引導卡改共享自適應材質。
        .tatwoAdaptiveMaterial(cornerRadius: 14)
    }
}

struct QuotaHubBottomFoldouts: View {
    @ObservedObject private var themeStore = TatwoThemeStore.shared
    let activity: [TatwoRecentActivityRecord]
    let activitySourceAccess: ExternalVolumeAccess?
    let activitySourceFailure: ExternalVolumeFailure?
    let activitySourceLastGoodAt: Date?
    let events: [QuotaProviderEvent]
    @Binding var showActivity: Bool
    @Binding var showEvents: Bool

    var body: some View {
        VStack(spacing: 10) {
            QuotaFoldoutSection(
                title: "動態",
                count: activity.count,
                symbol: "waveform.path.ecg",
                isExpanded: $showActivity
            ) {
                VStack(alignment: .leading, spacing: 7) {
                    if let activitySourceFailure {
                        Text(activitySourceLastGoodAt.map {
                            "Codex session activity 暫不可用（\(activitySourceFailure.rawValue)）；最後成功 \(Self.dateLabel($0))"
                        } ?? "Codex session activity 暫不可用（\(activitySourceFailure.rawValue)）")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    if activitySourceAccess == .notEnabled {
                        Text("Codex session activity 未啟用外接卷；目前只顯示本機派工來源。")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    if activity.isEmpty {
                        Text(activitySourceFailure == nil && activitySourceAccess != .notEnabled
                            ? "近 2 天無 agent 派工紀錄；今天的新派工會顯示於此。"
                            : activitySourceAccess == .notEnabled
                              ? "Codex session activity 尚未啟用；目前無法判斷外接卷上的派工紀錄。"
                              : "Codex session activity 暫不可用；請掛載外接卷或檢查權限。")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(activity) { record in
                            QuotaActivityRow(record: record)
                        }
                    }
                }
                .padding(.top, 8)
            }

            QuotaFoldoutSection(
                title: "事件",
                count: events.count,
                symbol: "exclamationmark.triangle",
                isExpanded: $showEvents
            ) {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(events) { event in
                        QuotaProviderEventRow(event: event)
                    }
                }
                .padding(.top, 8)
            }
        }
        .padding(13)
        .background(cleanQuotaBackground)
    }

    private static func dateLabel(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

struct QuotaFoldoutSection<Content: View>: View {
    let title: String
    let count: Int
    let symbol: String
    @Binding var isExpanded: Bool
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.spring(response: 0.24, dampingFraction: 0.88)) {
                    isExpanded.toggle()
                }
            } label: {
                QuotaFoldoutLabel(
                    title: title,
                    count: count,
                    symbol: symbol,
                    isExpanded: isExpanded
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(isExpanded ? "點擊整列收合" : "點擊整列展開")

            if isExpanded {
                content()
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}

struct QuotaFoldoutLabel: View {
    let title: String
    let count: Int
    let symbol: String
    let isExpanded: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.caption.weight(.black))
            Text(title)
                .font(.caption.weight(.black))
            Badge("\(count)")
            Spacer()
            Text(isExpanded ? "點擊收合" : "預設收合")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                .font(.caption2.weight(.black))
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

struct QuotaActivityRow: View {
    let record: TatwoRecentActivityRecord

    private var color: Color {
        switch record.sourceKind {
        case .dispatchRegistry: .blue
        case .codexSessionJSONL: record.modelConfidence == .explicitTurnContext ? .green : .orange
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(color)
                .frame(width: 9, height: 9)
                .padding(.top, 4)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(record.modelID)
                        .font(.caption.weight(.black))
                        .lineLimit(1)
                    Text(record.originator)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Text(record.updatedAt, style: .relative)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                Text("\(record.workdirSummary) · \(record.modelProvider) · \(activitySourceLabel(record))")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
    }

    private func activitySourceLabel(_ record: TatwoRecentActivityRecord) -> String {
        switch record.sourceKind {
        case .dispatchRegistry:
            return record.statusText
        case .codexSessionJSONL:
            return record.modelConfidence == .explicitTurnContext ? "Codex session JSONL" : "Codex session JSONL（model 未寫入 turn_context）"
        }
    }
}

private extension TatwoRecentActivityRecord {
    init(dispatchRecord record: TatwoDispatchRecord) {
        self.init(
            id: record.id,
            modelID: record.modelID.isEmpty ? record.bindingID : record.modelID,
            modelProvider: "TatwoDispatchRegistry",
            originator: record.identity.rawValue,
            workdirSummary: record.bindingID,
            statusText: record.status.rawValue,
            startedAt: record.startedAt,
            updatedAt: record.updatedAt,
            sourceKind: .dispatchRegistry,
            modelConfidence: .explicitTurnContext
        )
    }
}

struct QuotaProviderEvent: Identifiable {
    enum Severity {
        case normal, degraded, outage

        var color: Color {
            switch self {
            case .normal: .green
            case .degraded: .orange
            case .outage: .red
            }
        }
    }

    let id: String
    let providerName: String
    let title: String
    let detail: String
    let severity: Severity

    static func events(from rows: [LiveQuotaDisplay]) -> [QuotaProviderEvent] {
        let events = rows.compactMap { row -> QuotaProviderEvent? in
            switch row.status {
            case .missing:
                return QuotaProviderEvent(
                    id: "\(row.id)-outage",
                    providerName: row.displayName,
                    title: "中斷 / 需登入",
                    detail: row.caption,
                    severity: .outage)
            case .unknown where row.sourceBadge == "失敗" || row.sourceBadge.contains("timeout") || row.statusText.contains("失敗"):
                return QuotaProviderEvent(
                    id: "\(row.id)-degraded",
                    providerName: row.displayName,
                    title: "降級",
                    detail: row.caption,
                    severity: .degraded)
            default:
                return nil
            }
        }
        if events.isEmpty {
            return [
                QuotaProviderEvent(
                    id: "providers-normal",
                    providerName: "Provider",
                    title: "未偵測到重大降級/中斷",
                    detail: "無 live 來源的模型已在卡片內標示，不當作正常用量。",
                    severity: .normal)
            ]
        }
        return events
    }
}

struct QuotaProviderEventRow: View {
    let event: QuotaProviderEvent

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(event.severity.color)
                .frame(width: 9, height: 9)
                .padding(.top, 4)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(event.providerName) · \(event.title)")
                    .font(.caption.weight(.black))
                Text(event.detail)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
    }
}




struct SimpleQuotaBar: View {
    let percent: Int?
    let height: CGFloat
    var colors: [Color] = [.cyan.opacity(0.62), .mint.opacity(0.90)]

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                // 額度條軌道：極光白軌、fable5 暖紙軌（白軌在牛皮紙上突兀）。
                Capsule().fill(
                    TatwoActivePalette.current.usesGlass
                        ? AnyShapeStyle(Color.white.opacity(0.42))
                        : AnyShapeStyle(TatwoActivePalette.current.surfaceFill))
                if let percent {
                    Capsule()
                        .fill(LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(10, proxy.size.width * CGFloat(percent) / 100.0))
                } else {
                    Capsule()
                        .fill(Color.gray.opacity(0.26))
                        .frame(width: max(8, proxy.size.width * 0.08))
                }
            }
        }
        .frame(height: height)
    }
}


var cleanQuotaBackground: some View {
    RoundedRectangle(cornerRadius: LiquidGlassTokens.radiusCard, style: LiquidGlassTokens.shapeStyle)
        .fill(.ultraThinMaterial)
        .overlay {
            RoundedRectangle(cornerRadius: LiquidGlassTokens.radiusCard, style: LiquidGlassTokens.shapeStyle)
                .fill(LiquidGlassTokens.tint.opacity(LiquidGlassTokens.tintOpacity))
        }
        .overlay(alignment: .topLeading) {
            LinearGradient(
                colors: [
                    LiquidGlassTokens.tint.opacity(0.24),
                    Color.cyan.opacity(0.08),
                    Color.clear
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .clipShape(RoundedRectangle(cornerRadius: LiquidGlassTokens.radiusCard, style: LiquidGlassTokens.shapeStyle))
        }
        .overlay(
            RoundedRectangle(cornerRadius: LiquidGlassTokens.radiusCard, style: LiquidGlassTokens.shapeStyle)
                .strokeBorder(LiquidGlassTokens.tint.opacity(LiquidGlassTokens.strokeOpacity), lineWidth: 1)
        )
        .shadow(
            color: .black.opacity(LiquidGlassTokens.shadowOpacity),
            radius: LiquidGlassTokens.shadowRadius,
            x: LiquidGlassTokens.shadowOffsetX,
            y: LiquidGlassTokens.shadowOffsetY
        )
}

struct LiveQuotaDeckSnapshot: Sendable {
    var loadedAt: Date?
    var rows: [String: LiveQuotaDisplay]

    static let loading = LiveQuotaDeckSnapshot(loadedAt: nil, rows: [:])

    var headerText: String {
        guard let loadedAt else { return "讀取中" }
        return "live \(Self.headerFormatter.string(from: loadedAt))"
    }

    func isStale(maxAge: TimeInterval, now: Date = Date()) -> Bool {
        guard let loadedAt else { return true }
        return now.timeIntervalSince(loadedAt) > maxAge
    }

    func display(for provider: UsageProviderStatus) -> LiveQuotaDisplay {
        rows[provider.id] ?? .pending(provider)
    }

    private static let headerFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_Hant_TW")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
}

struct LiveQuotaDisplay: Identifiable, Sendable {
    let id: String
    let displayName: String
    let planLabel: String
    let status: InstallState
    let statusText: String
    let caption: String
    let permissionLabel: String
    let sourceBadge: String
    let remainingPercent: Int?
    let primaryRemainingPercent: Int?
    let secondaryRemainingPercent: Int?
    let primaryResetAt: Date?
    let secondaryResetAt: Date?
    let resetCreditsAvailable: Int?
    let resetCreditsExpiresAt: Date?
    let resetCreditExpiryDates: [Date]

    var isPending: Bool {
        status == .unknown && statusText == "讀取中" && loadedSourceIsPending
    }

    private var loadedSourceIsPending: Bool {
        sourceBadge == "live" && remainingPercent == nil && primaryRemainingPercent == nil && secondaryRemainingPercent == nil
    }

    var displayRemainingPercent: Int? {
        codexWindowExpired ? nil : remainingPercent
    }

    var displayStatusText: String {
        codexWindowExpired ? "刷新中" : statusText
    }

    var hasLiveUsage: Bool {
        remainingPercent != nil
            || primaryRemainingPercent != nil
            || secondaryRemainingPercent != nil
            || resetCreditsAvailable != nil
    }

    private var codexWindowExpired: Bool {
        guard id == "codex-gpt" else { return false }
        let now = Date()
        return [primaryResetAt, secondaryResetAt].contains { date in
            guard let date else { return false }
            return date <= now
        }
    }

    static func pending(_ provider: UsageProviderStatus) -> LiveQuotaDisplay {
        LiveQuotaDisplay(
            id: provider.id,
            displayName: provider.displayName,
            planLabel: cleanPlanLabel(provider.id),
            status: .unknown,
            statusText: "讀取中",
            caption: provider.liveRefreshPolicy,
            permissionLabel: provider.quotaLabel,
            sourceBadge: "live",
            remainingPercent: nil,
            primaryRemainingPercent: nil,
            secondaryRemainingPercent: nil,
            primaryResetAt: nil,
            secondaryResetAt: nil,
            resetCreditsAvailable: nil,
            resetCreditsExpiresAt: nil,
            resetCreditExpiryDates: []
        )
    }

    static func unverified(_ provider: UsageProviderStatus, caption: String? = nil) -> LiveQuotaDisplay {
        LiveQuotaDisplay(
            id: provider.id,
            displayName: provider.displayName,
            planLabel: cleanPlanLabel(provider.id),
            status: provider.status == .missing ? .missing : .unknown,
            statusText: provider.status == .missing ? "需設定" : "未接入",
            caption: caption ?? "尚未接 live 用量來源",
            permissionLabel: provider.quotaLabel,
            sourceBadge: "無 live",
            remainingPercent: nil,
            primaryRemainingPercent: nil,
            secondaryRemainingPercent: nil,
            primaryResetAt: nil,
            secondaryResetAt: nil,
            resetCreditsAvailable: nil,
            resetCreditsExpiresAt: nil,
            resetCreditExpiryDates: []
        )
    }
}

enum TatwoLiveQuotaReader {
    static func load(
        providers: [UsageProviderStatus],
        allowExternalAccess: Bool = false,
        openAIAccountSnapshotReader:
            @escaping @Sendable () async ->
                ChatNativeSubscriptionAccountSnapshot = {
                await ChatNativeSubscriptionAccountService()
                    .quotaSnapshot()
            },
        openAIHomeURL: URL =
            ChatNativeSubscriptionHomeLocator().resolve(),
        claudeAccountStatusReader:
            @escaping @Sendable () async ->
                ChatNativeClaudeSubscriptionAccountStatus = {
                await ChatNativeClaudeSubscriptionAccountService()
                    .status()
            },
        claudeUsageClient:
            any ClaudeOAuthUsageQuerying = ClaudeOAuthUsageClient()
    ) async -> LiveQuotaDeckSnapshot {
        var rows: [String: LiveQuotaDisplay] = [:]
        async let codexRow = loadCodex(
            provider: providers.first { $0.id == "codex-gpt" },
            allowExternalAccess: allowExternalAccess,
            accountSnapshotReader: openAIAccountSnapshotReader,
            homeURL: openAIHomeURL
        )
        async let claudeRow = loadClaude(
            provider: providers.first { $0.id == "claude" },
            accountStatusReader: claudeAccountStatusReader,
            usageClient: claudeUsageClient)
        async let grokRow = loadGrok(
            provider: providers.first { $0.id == "grok" })
        async let miniMaxRow = loadMiniMax(
            provider: providers.first { $0.id == "minimax" })

        if let row = await codexRow { rows[row.id] = row }
        if let row = await claudeRow { rows[row.id] = row }
        if let row = await grokRow { rows[row.id] = row }
        if let row = await miniMaxRow { rows[row.id] = row }

        for provider in providers where rows[provider.id] == nil {
            rows[provider.id] = .unverified(provider)
        }
        return LiveQuotaDeckSnapshot(loadedAt: Date(), rows: rows)
    }

    static func loadCodex(
        provider: UsageProviderStatus?,
        allowExternalAccess: Bool,
        accountSnapshotReader:
            @escaping @Sendable () async ->
                ChatNativeSubscriptionAccountSnapshot = {
                await ChatNativeSubscriptionAccountService()
                    .quotaSnapshot()
            },
        homeURL: URL =
            ChatNativeSubscriptionHomeLocator().resolve()
    ) async -> LiveQuotaDisplay? {
        guard let provider else { return nil }
        if shouldSkipCodexExternalVolumeRead(
            homeURL: homeURL,
            allowExternalAccess: allowExternalAccess)
        {
            return LiveQuotaDisplay(
                id: provider.id,
                displayName: provider.displayName,
                planLabel: "CODEX",
                status: .unknown,
                statusText: "手動刷新",
                caption: "避免開啟工具列時跳外接卷權限；按 live 後再授權讀取",
                permissionLabel: provider.quotaLabel,
                sourceBadge: "待授權",
                remainingPercent: nil,
                primaryRemainingPercent: nil,
                secondaryRemainingPercent: nil,
                primaryResetAt: nil,
                secondaryResetAt: nil,
                resetCreditsAvailable: nil,
                resetCreditsExpiresAt: nil,
                resetCreditExpiryDates: []
            )
        }
        let accountSnapshot = await accountSnapshotReader()
        switch accountSnapshot.status {
        case .unavailable:
            return codexAccountOnlyDisplay(
                provider: provider,
                status: .unknown,
                statusText: "執行環境不可用",
                caption: "TATWO 內建 OpenAI 執行環境不可用",
                sourceBadge: "無 live")
        case .signedOut:
            return codexAccountOnlyDisplay(
                provider: provider,
                status: .missing,
                statusText: "需登入",
                caption: "ChatGPT 訂閱帳號尚未登入",
                sourceBadge: "無 live")
        case .requiresReauthentication:
            return codexAccountOnlyDisplay(
                provider: provider,
                status: .missing,
                statusText: "需重新登入",
                caption: "ChatGPT 登入狀態已到期；請重新登入",
                sourceBadge: "無 live")
        case .signedIn:
            break
        }
        guard let rateLimits = accountSnapshot.rateLimits else {
            let failureCaption = accountSnapshot
                .rateLimitFailure?
                .rawValue
            return codexAccountOnlyDisplay(
                provider: provider,
                accountStatus: accountSnapshot.status,
                status: .installed,
                statusText: "已登入",
                caption: failureCaption
                    .map {
                        "ChatGPT 訂閱已登入；無 live 用量（\($0)）"
                    }
                    ?? "ChatGPT 訂閱已登入；額度來源未回傳數字",
                sourceBadge: failureCaption == nil
                    ? "無 live"
                    : "失敗")
        }
        let hasUsage =
            rateLimits.primaryRemainingPercent != nil
            || rateLimits.secondaryRemainingPercent != nil
        return LiveQuotaDisplay(
            id: provider.id,
            displayName: provider.displayName,
            planLabel: codexPlanLabel(
                accountStatus: accountSnapshot.status,
                usagePlan: rateLimits.planType),
            status: .installed,
            statusText: hasUsage ? "live" : "已登入",
            caption: "5小時 / 1週 / Codex重置額度分開顯示",
            permissionLabel: provider.quotaLabel,
            sourceBadge: "Codex live",
            remainingPercent: rateLimits.remainingPercent,
            primaryRemainingPercent:
                rateLimits.primaryRemainingPercent,
            secondaryRemainingPercent:
                rateLimits.secondaryRemainingPercent,
            primaryResetAt:
                dateFromEpoch(rateLimits.primaryResetsAt),
            secondaryResetAt:
                dateFromEpoch(rateLimits.secondaryResetsAt),
            resetCreditsAvailable:
                rateLimits.resetCreditsAvailable,
            resetCreditsExpiresAt:
                rateLimits.resetCreditExpiryDates
                    .min()
                    .flatMap { dateFromEpoch($0) },
            resetCreditExpiryDates:
                rateLimits.resetCreditExpiryDates
                    .compactMap { dateFromEpoch($0) })
    }

    static func loadClaude(
        provider: UsageProviderStatus?,
        accountStatusReader:
            @escaping @Sendable () async ->
                ChatNativeClaudeSubscriptionAccountStatus = {
                await ChatNativeClaudeSubscriptionAccountService()
                    .status()
            },
        usageClient:
            any ClaudeOAuthUsageQuerying = ClaudeOAuthUsageClient()
    ) async -> LiveQuotaDisplay? {
        guard let provider else { return nil }
        let accountStatus = await accountStatusReader()
        let subscriptionType: String
        switch accountStatus {
        case .unavailable:
            return LiveQuotaDisplay(
                id: provider.id,
                displayName: provider.displayName,
                planLabel: "CLAUDE",
                status: .unknown,
                statusText: "執行環境不可用",
                caption: "TATWO 內建 Claude 執行環境不可用",
                permissionLabel: "未判定 · 不顯示用量",
                sourceBadge: "無 live",
                remainingPercent: nil,
                primaryRemainingPercent: nil,
                secondaryRemainingPercent: nil,
                primaryResetAt: nil,
                secondaryResetAt: nil,
                resetCreditsAvailable: nil,
                resetCreditsExpiresAt: nil,
                resetCreditExpiryDates: []
            )
        case .signedOut:
            return LiveQuotaDisplay(
                id: provider.id,
                displayName: provider.displayName,
                planLabel: "CLAUDE",
                status: .missing,
                statusText: "需登入",
                caption: "Claude 訂閱帳號尚未登入",
                permissionLabel: "不顯示假用量",
                sourceBadge: "無 live",
                remainingPercent: nil,
                primaryRemainingPercent: nil,
                secondaryRemainingPercent: nil,
                primaryResetAt: nil,
                secondaryResetAt: nil,
                resetCreditsAvailable: nil,
                resetCreditsExpiresAt: nil,
                resetCreditExpiryDates: []
            )
        case .signedIn(let value):
            subscriptionType = value
        }
        let plan = subscriptionType.trimmingCharacters(
            in: .whitespacesAndNewlines)
        let normalizedPlan = plan.lowercased()
        let planLabel = plan.isEmpty ? "CLAUDE" : plan.uppercased()
        let reviewerReady = ["max", "pro", "team", "enterprise"].contains(normalizedPlan)
        do {
            let usage = try await usageClient.queryUsage()
            let fiveHourRemaining = remainingPercent(
                from: usage.fiveHour.utilization)
            let sevenDayRemaining = remainingPercent(
                from: usage.sevenDay.utilization)
            return LiveQuotaDisplay(
                id: provider.id,
                displayName: provider.displayName,
                planLabel: planLabel,
                status: reviewerReady ? .installed : .unknown,
                statusText: reviewerReady ? "live" : "需確認",
                caption: "5小時 / 7天 live 用量",
                permissionLabel:
                    "Claude · \(planLabel)",
                sourceBadge: "Claude live",
                remainingPercent: fiveHourRemaining,
                primaryRemainingPercent: fiveHourRemaining,
                secondaryRemainingPercent: sevenDayRemaining,
                primaryResetAt: usage.fiveHour.resetsAt,
                secondaryResetAt: usage.sevenDay.resetsAt,
                resetCreditsAvailable: nil,
                resetCreditsExpiresAt: nil,
                resetCreditExpiryDates: []
            )
        } catch {
            let usageError = error as? ClaudeOAuthUsageError
            let reason = usageError?
                .fallbackReason ?? "未知錯誤"
            if usageError == .unauthorized {
                return LiveQuotaDisplay(
                    id: provider.id,
                    displayName: provider.displayName,
                    planLabel: planLabel,
                    status: .missing,
                    statusText: "需重新登入",
                    caption: reason,
                    permissionLabel: "Claude · \(planLabel) · 不顯示假用量",
                    sourceBadge: "無 live",
                    remainingPercent: nil,
                    primaryRemainingPercent: nil,
                    secondaryRemainingPercent: nil,
                    primaryResetAt: nil,
                    secondaryResetAt: nil,
                    resetCreditsAvailable: nil,
                    resetCreditsExpiresAt: nil,
                    resetCreditExpiryDates: []
                )
            }
            return LiveQuotaDisplay(
                id: provider.id,
                displayName: provider.displayName,
                planLabel: planLabel,
                status: reviewerReady ? .installed : .unknown,
                statusText: reviewerReady ? "授權OK" : "需確認",
                caption: reviewerReady
                    ? "\(planLabel)；無 live 用量（\(reason)）；Fable5 主導＋Opus 副審授權OK"
                    : "Claude 訂閱已登入；無 live 用量（\(reason)）",
                permissionLabel:
                    "Claude · \(planLabel) · 非用量",
                sourceBadge: "無 live",
                remainingPercent: nil,
                primaryRemainingPercent: nil,
                secondaryRemainingPercent: nil,
                primaryResetAt: nil,
                secondaryResetAt: nil,
                resetCreditsAvailable: nil,
                resetCreditsExpiresAt: nil,
                resetCreditExpiryDates: []
            )
        }
    }

    static func loadGrok(
        provider: UsageProviderStatus?,
        snapshotReader:
            @escaping @Sendable () async ->
                TatwoLocalUsageSnapshot = {
                await TatwoLocalUsageMeter.shared.snapshot(
                    provider: "grok")
            }
    ) async -> LiveQuotaDisplay? {
        guard let provider else { return nil }
        return localUsageDisplay(
            provider: provider,
            snapshot: await snapshotReader(),
            caption:
                "來源＝App 自身記錄；非 Grok 官方訂閱餘額。")
    }

    static func loadMiniMax(
        provider: UsageProviderStatus?,
        snapshotReader:
            @escaping @Sendable () async ->
                TatwoLocalUsageSnapshot = {
                await TatwoLocalUsageMeter.shared.snapshot(
                    provider: "minimax")
            }
    ) async -> LiveQuotaDisplay? {
        guard let provider else { return nil }
        return localUsageDisplay(
            provider: provider,
            snapshot: await snapshotReader(),
            caption:
                "來源＝App 自身記錄；接 admin key 可顯示官方餘額。")
    }

    private static func remainingPercent(
        from utilization: Double
    ) -> Int {
        Int(max(0, min(100, 100 - utilization)).rounded())
    }

    private static func localUsageDisplay(
        provider: UsageProviderStatus,
        snapshot: TatwoLocalUsageSnapshot,
        caption: String
    ) -> LiveQuotaDisplay {
        LiveQuotaDisplay(
            id: provider.id,
            displayName: provider.displayName,
            planLabel: cleanPlanLabel(provider.id),
            status: provider.status == .missing
                ? .missing
                : .installed,
            statusText: snapshot.hasRecordedUsage
                ? localUsageSummary(snapshot)
                : "尚無本機用量",
            caption: caption,
            permissionLabel: "App 本機記錄",
            sourceBadge: "本機計量",
            remainingPercent: nil,
            primaryRemainingPercent: nil,
            secondaryRemainingPercent: nil,
            primaryResetAt: nil,
            secondaryResetAt: nil,
            resetCreditsAvailable: nil,
            resetCreditsExpiresAt: nil,
            resetCreditExpiryDates: [])
    }

    private static func localUsageSummary(
        _ snapshot: TatwoLocalUsageSnapshot
    ) -> String {
        [
            localUsageWindow(
                label: "5小時",
                aggregate: snapshot.fiveHour),
            localUsageWindow(
                label: "7天",
                aggregate: snapshot.sevenDay),
        ].joined(separator: "／")
    }

    private static func localUsageWindow(
        label: String,
        aggregate: TatwoLocalUsageAggregate
    ) -> String {
        let requests =
            "\(label) \(aggregate.requestCount) 次請求"
        guard let tokens = aggregate.totalTokens else {
            return requests
        }
        return "\(requests)（\(tokens) tokens）"
    }

    private static func dateFromEpoch(_ value: Int?) -> Date? {
        guard let value, value > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(value))
    }

    private static func codexAccountOnlyDisplay(
        provider: UsageProviderStatus,
        accountStatus: ChatNativeSubscriptionAccountStatus = .signedOut,
        status: InstallState,
        statusText: String,
        caption: String,
        sourceBadge: String
    ) -> LiveQuotaDisplay {
        LiveQuotaDisplay(
            id: provider.id,
            displayName: provider.displayName,
            planLabel: codexPlanLabel(
                accountStatus: accountStatus,
                usagePlan: nil),
            status: status,
            statusText: statusText,
            caption: caption,
            permissionLabel: provider.quotaLabel,
            sourceBadge: sourceBadge,
            remainingPercent: nil,
            primaryRemainingPercent: nil,
            secondaryRemainingPercent: nil,
            primaryResetAt: nil,
            secondaryResetAt: nil,
            resetCreditsAvailable: nil,
            resetCreditsExpiresAt: nil,
            resetCreditExpiryDates: [])
    }

    private static func codexPlanLabel(
        accountStatus: ChatNativeSubscriptionAccountStatus,
        usagePlan: String?
    ) -> String {
        if case .signedIn(let planType) = accountStatus {
            let plan = planType.trimmingCharacters(
                in: .whitespacesAndNewlines)
            if !plan.isEmpty, plan.lowercased() != "unknown" {
                return plan.uppercased()
            }
        }
        let plan = usagePlan?.trimmingCharacters(
            in: .whitespacesAndNewlines) ?? ""
        return plan.isEmpty ? "CODEX" : plan
    }

    private static func shouldSkipCodexExternalVolumeRead(
        homeURL: URL,
        allowExternalAccess: Bool
    ) -> Bool {
        guard !allowExternalAccess else { return false }
        return homeURL.path.hasPrefix("/Volumes/")
            || homeURL.resolvingSymlinksInPath().path.hasPrefix(
                "/Volumes/")
    }
}

func cleanPlanLabel(_ id: String) -> String {
    switch id {
    case "codex-gpt": "CODEX"
    case "claude": "CLAUDE"
    case "grok": "GROK"
    case "minimax": "MINIMAX"
    default: "LOCAL"
    }
}

func quotaProviderSymbol(_ id: String) -> String {
    switch id {
    case "codex-gpt": "sparkles.rectangle.stack"
    case "claude": "brain.head.profile"
    case "grok": "antenna.radiowaves.left.and.right"
    case "minimax": "square.stack.3d.up.fill"
    case "local-api": "server.rack"
    default: "cpu"
    }
}

func quotaBrandColors(_ id: String) -> [Color] {
    switch id {
    case "codex-gpt":
        return [Color(red: 0.16, green: 0.58, blue: 1.0), Color(red: 0.14, green: 0.86, blue: 0.72)]
    case "claude":
        return [Color(red: 0.88, green: 0.39, blue: 0.18), Color(red: 1.0, green: 0.70, blue: 0.32)]
    case "grok":
        return [Color(red: 0.24, green: 0.25, blue: 0.30), Color(red: 0.54, green: 0.58, blue: 0.66)]
    case "minimax":
        return [Color(red: 0.52, green: 0.35, blue: 1.0), Color(red: 0.92, green: 0.40, blue: 1.0)]
    case "local-api":
        return [Color(red: 0.15, green: 0.75, blue: 0.44), Color(red: 0.52, green: 0.90, blue: 0.26)]
    default:
        return [.cyan.opacity(0.62), .mint.opacity(0.90)]
    }
}

func integrationGuideText(_ id: String) -> String {
    switch id {
    case "claude":
        return "先確認 Claude CLI 登入/方案；此頁只顯示授權狀態，不偽造剩餘百分比。"
    case "grok":
        return "目前顯示 App 自身的本機計量；Grok 無官方訂閱額度來源。"
    case "minimax":
        return "目前顯示 App 自身的本機計量；接 admin key 可顯示官方餘額。"
    case "local-api":
        return "設定本地 endpoint 或使用者批准的 API lane 後再顯示；不保存 key。"
    default:
        return "按 live 重新整理；若來源不可用，會標明無 live source。"
    }
}

func statusColor(_ state: InstallState) -> Color {
    switch state {
    case .installed: .green
    case .unknown: .gray.opacity(0.86)
    case .missing: .red
    case .skipped: .orange
    }
}

func percentText(_ value: Int?) -> String {
    guard let value else { return "—" }
    return "\(value)%"
}

func compactWindowText(_ row: LiveQuotaDisplay) -> String {
    if row.sourceBadge == "本機計量" {
        return row.statusText
    }
    if row.primaryRemainingPercent == nil && row.secondaryRemainingPercent == nil {
        return "尚無即時用量"
    }
    if row.primaryResetAt.map({ $0 <= Date() }) == true || row.secondaryResetAt.map({ $0 <= Date() }) == true {
        return "重置中 · live刷新"
    }
    return "5小時 \(percentText(row.primaryRemainingPercent)) · 1週 \(percentText(row.secondaryRemainingPercent))"
}

func resetText(_ date: Date?) -> String {
    guard let date else { return "未回傳" }
    return "到期 \(resetDateFormatter.string(from: date))"
}

func expiredResetText(_ date: Date?) -> String {
    guard let date else { return "已到期" }
    return "已到期 \(resetDateFormatter.string(from: date))"
}

func resetCreditExpiryText(_ dates: [Date], fallback: Date?) -> String {
    var seen = Set<String>()
    let uniqueDates = dates.sorted().compactMap { date -> String? in
        let text = resetCreditDateFormatter.string(from: date)
        guard !seen.contains(text) else { return nil }
        seen.insert(text)
        return text
    }
    if !uniqueDates.isEmpty {
        return "到期 \(uniqueDates.prefix(3).joined(separator: "、"))"
    }
    guard let fallback else { return "到期未回傳" }
    return "到期 \(resetCreditDateFormatter.string(from: fallback))"
}

let resetDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "zh_Hant_TW")
    formatter.dateFormat = "M/d HH:mm"
    return formatter
}()

let resetCreditDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "zh_Hant_TW")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyy/M/d"
    return formatter
}()
