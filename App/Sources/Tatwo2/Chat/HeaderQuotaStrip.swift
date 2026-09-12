// 照搬自 Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac/HeaderQuotaStrip.swift；改動 4 行（原因：移除舊 Core import，改接同名 Facade 假資料）
import SwiftUI
import Combine

enum HeaderQuotaStripMetrics {
    static let visualWidth: CGFloat = 60
    static let visualHeight: CGFloat = 4
    static let hitHeight: CGFloat = 24
    static let segmentSpacing: CGFloat = 2

    static func visualWidth(forWindowWidth _: CGFloat) -> CGFloat {
        visualWidth
    }
}

enum HeaderQuotaSegmentState: Equatable {
    case live
    case critical
    case stale
    case unknown
}

enum HeaderQuotaAlert: Equatable {
    case none
    case amber
    case red
}

struct HeaderQuotaRemainingValue: Equatable {
    let percent: Int?
    let fallbackText: String?

    func map(
        _ transform: (Int) -> String
    ) -> String? {
        percent.map(transform) ?? fallbackText
    }
}

struct HeaderQuotaSegment: Identifiable, Equatable {
    let id: String
    let displayName: String
    let remainingPercent: HeaderQuotaRemainingValue
    let fillFraction: Double
    let resetAt: Date?
    let state: HeaderQuotaSegmentState
    let tooltip: String
    let detailText: String?

    var valueText: String {
        remainingPercent.map { "\($0)%" } ?? detailText ?? "讀取中"
    }
}

struct HeaderQuotaStripModel {
    static let staleAfter: TimeInterval = 300

    let segments: [HeaderQuotaSegment]
    let alert: HeaderQuotaAlert

    init(
        providers: [UsageProviderStatus],
        snapshot: LiveQuotaDeckSnapshot,
        now: Date = Date()
    ) {
        let isStale = snapshot.loadedAt.map { now.timeIntervalSince($0) > Self.staleAfter } ?? true
        segments = providers.compactMap { provider in
            let row = snapshot.display(for: provider)
            guard row.status != .missing, row.status != .skipped else { return nil }

            let codexWindowExpired = row.id == "codex-gpt"
                && [row.primaryResetAt, row.secondaryResetAt].contains { resetAt in
                    guard let resetAt else { return false }
                    return resetAt <= now
                }
            let percent = codexWindowExpired
                ? nil
                : row.remainingPercent.map { min(100, max(0, $0)) }
            let state: HeaderQuotaSegmentState
            if isStale {
                state = .stale
            } else if let percent, row.hasLiveUsage {
                state = percent <= 15 ? .critical : .live
            } else {
                state = .unknown
            }

            let resetAt = row.primaryResetAt ?? row.secondaryResetAt
            let detailText = percent == nil
                ? Self.detailText(for: row)
                : nil
            return HeaderQuotaSegment(
                id: row.id,
                displayName: row.displayName,
                remainingPercent: HeaderQuotaRemainingValue(
                    percent: percent,
                    fallbackText: detailText),
                fillFraction: Double(percent ?? 0) / 100,
                resetAt: resetAt,
                state: state,
                tooltip: Self.tooltip(
                    displayName: row.displayName,
                    percent: percent,
                    resetAt: resetAt,
                    detailText: detailText),
                detailText: detailText
            )
        }

        let criticalPercents = segments.compactMap { segment -> Int? in
            guard segment.state == .critical else { return nil }
            return segment.remainingPercent.percent
        }
        if criticalPercents.contains(where: { $0 <= 5 }) {
            alert = .red
        } else if !criticalPercents.isEmpty {
            alert = .amber
        } else {
            alert = .none
        }
    }

    private static func detailText(
        for row: LiveQuotaDisplay
    ) -> String {
        if row.isPending {
            return "讀取中"
        }
        let caption = row.caption.trimmingCharacters(
            in: .whitespacesAndNewlines)
        return caption.isEmpty ? row.displayStatusText : caption
    }

    private static func tooltip(
        displayName: String,
        percent: Int?,
        resetAt: Date?,
        detailText: String?
    ) -> String {
        let remaining = percent.map { "\($0)%" }
            ?? detailText
            ?? "讀取中"
        let reset = resetAt.map { HeaderQuotaDateFormatters.tooltip.string(from: $0) } ?? "—"
        return "\(displayName) · \(remaining) · reset \(reset)"
    }
}

enum HeaderQuotaSnapshotFixture {
    static func make(
        kind: String?,
        providers: [UsageProviderStatus],
        now: Date = Date()
    ) -> LiveQuotaDeckSnapshot? {
        guard let kind = kind?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              ["normal", "critical", "critical-red"].contains(kind)
        else { return nil }

        var rows: [String: LiveQuotaDisplay] = [:]
        for (index, provider) in providers.enumerated() {
            let percent: Int?
            if index == 0, kind == "critical-red" {
                percent = 5
            } else if index == 0, kind == "critical" {
                percent = 8
            } else if index < 2 {
                percent = index == 0 ? 72 : 46
            } else {
                percent = nil
            }
            rows[provider.id] = LiveQuotaDisplay(
                id: provider.id,
                displayName: provider.displayName,
                planLabel: provider.displayName.uppercased(),
                status: percent == nil ? .unknown : .installed,
                statusText: percent == nil ? "未接入" : "live",
                caption: "export-only quota fixture",
                permissionLabel: provider.quotaLabel,
                sourceBadge: percent == nil ? "無 live" : "live",
                remainingPercent: percent,
                primaryRemainingPercent: percent,
                secondaryRemainingPercent: nil,
                primaryResetAt: percent == nil ? nil : now.addingTimeInterval(3_600),
                secondaryResetAt: nil,
                resetCreditsAvailable: nil,
                resetCreditsExpiresAt: nil,
                resetCreditExpiryDates: []
            )
        }
        return LiveQuotaDeckSnapshot(loadedAt: now, rows: rows)
    }
}

struct TatwoHeaderQuotaStrip: View {
    @ObservedObject private var themeStore = TatwoThemeStore.shared
    let providers: [UsageProviderStatus]
    let openUsage: () -> Void
    @State private var liveSnapshot: LiveQuotaDeckSnapshot
    @State private var isPopoverPresented = false
    @State private var isRefreshing = false
    private let refreshTimer = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    init(
        providers: [UsageProviderStatus],
        initialLiveSnapshot: LiveQuotaDeckSnapshot? = nil,
        openUsage: @escaping () -> Void
    ) {
        self.providers = providers
        self.openUsage = openUsage
        _liveSnapshot = State(initialValue: initialLiveSnapshot ?? .loading)
    }

    private var model: HeaderQuotaStripModel {
        HeaderQuotaStripModel(providers: providers, snapshot: liveSnapshot)
    }

    var body: some View {
        Button {
            isPopoverPresented.toggle()
        } label: {
            strip
                .contentShape(Rectangle())
                .frame(width: HeaderQuotaStripMetrics.visualWidth)
                .frame(height: HeaderQuotaStripMetrics.hitHeight)
        }
        .buttonStyle(.plain)
        .help(model.segments.map(\.tooltip).joined(separator: "\n"))
        .accessibilityLabel("Live quota")
        .accessibilityValue(accessibilityValue)
        .popover(isPresented: $isPopoverPresented, arrowEdge: .top) {
            HeaderQuotaPopover(
                model: model,
                isRefreshing: isRefreshing,
                refresh: {
                    Task {
                        await refresh(
                            allowExternalAccess: true,
                            refreshKind: .manual)
                    }
                },
                openUsage: {
                    isPopoverPresented = false
                    openUsage()
                }
            )
        }
        .onReceive(NotificationCenter.default.publisher(for: .tatwoShowLiveQuotaPopover)) { _ in
            isPopoverPresented = true
        }
        .task {
            await refreshIfStale(maxAge: 10)
        }
        .onReceive(refreshTimer) { _ in
            Task {
                await refresh(
                    allowExternalAccess: false,
                    refreshKind: .automatic)
            }
        }
    }

    private var strip: some View {
        HStack(spacing: HeaderQuotaStripMetrics.segmentSpacing) {
            if model.segments.isEmpty {
                Capsule()
                    .fill(Color.secondary.opacity(0.18))
            } else {
                ForEach(model.segments) { segment in
                    HeaderQuotaSegmentView(segment: segment)
                }
            }
        }
        .frame(height: HeaderQuotaStripMetrics.visualHeight)
        .padding(.horizontal, 3)
        .padding(.vertical, 3)
        .tatwoAdaptiveCapsule()
        .background(LiquidGlassTokens.tint.opacity(LiquidGlassTokens.tintOpacity), in: Capsule())
        .overlay {
            Capsule()
                .strokeBorder(alertColor.opacity(alertOpacity), lineWidth: model.alert == .none ? 1 : 1.5)
        }
        .shadow(
            color: .black.opacity(LiquidGlassTokens.shadowOpacity),
            radius: LiquidGlassTokens.shadowRadius,
            x: LiquidGlassTokens.shadowOffsetX,
            y: LiquidGlassTokens.shadowOffsetY
        )
    }

    private var alertColor: Color {
        switch model.alert {
        case .none: LiquidGlassTokens.tint
        case .amber: .orange
        case .red: .red
        }
    }

    private var alertOpacity: Double {
        model.alert == .none ? LiquidGlassTokens.strokeOpacity : 0.82
    }

    private var accessibilityValue: String {
        guard !model.segments.isEmpty else { return "No active quota providers" }
        return model.segments.map(\.tooltip).joined(separator: ", ")
    }

    @MainActor
    private func refreshIfStale(maxAge: TimeInterval) async {
        guard liveSnapshot.isStale(maxAge: maxAge) else { return }
        await refresh(
            allowExternalAccess: false,
            refreshKind: .automatic)
    }

    @MainActor
    private func refresh(
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
}

private struct HeaderQuotaSegmentView: View {
    let segment: HeaderQuotaSegment

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(backgroundColor)
                if segment.fillFraction > 0 {
                    Capsule()
                        .fill(fillStyle)
                        .frame(width: geometry.size.width * segment.fillFraction)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .help(segment.tooltip)
        .accessibilityHidden(true)
    }

    private var backgroundColor: Color {
        switch segment.state {
        case .live, .critical: Color.secondary.opacity(0.16)
        case .stale: Color.secondary.opacity(0.26)
        case .unknown: Color.secondary.opacity(0.20)
        }
    }

    private var fillStyle: AnyShapeStyle {
        switch segment.state {
        case .live, .critical:
            AnyShapeStyle(LinearGradient(
                colors: quotaBrandColors(segment.id),
                startPoint: .leading,
                endPoint: .trailing
            ))
        case .stale, .unknown:
            AnyShapeStyle(Color.secondary.opacity(0.40))
        }
    }
}

private struct HeaderQuotaPopover: View {
    @ObservedObject private var themeStore = TatwoThemeStore.shared
    let model: HeaderQuotaStripModel
    let isRefreshing: Bool
    let refresh: () -> Void
    let openUsage: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Live quota")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                Spacer(minLength: 12)
                Button(action: refresh) {
                    Image(systemName: isRefreshing ? "arrow.triangle.2.circlepath" : "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .disabled(isRefreshing)
                .help("重新整理 live quota")
            }

            if model.segments.isEmpty {
                Text("沒有啟用中的 provider")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.segments) { segment in
                    HStack(spacing: 8) {
                        Circle()
                            .fill(segmentColor(segment))
                            .frame(width: 7, height: 7)
                        Text(segment.displayName)
                            .lineLimit(1)
                        Spacer(minLength: 12)
                        Text(segment.valueText)
                            .monospacedDigit()
                            .lineLimit(1)
                            .foregroundStyle(segment.state == .critical ? alertForeground : Color.secondary)
                        Text(segment.resetAt.map { HeaderQuotaDateFormatters.compact.string(from: $0) } ?? "—")
                            .monospacedDigit()
                            .foregroundStyle(.tertiary)
                    }
                    .font(.caption)
                }
            }

            Divider()
            Button("完整 Usage", action: openUsage)
                .buttonStyle(.plain)
                .font(.caption.weight(.semibold))
        }
        .padding(12)
        .frame(width: 250)
        .background(LiquidGlassTokens.tint.opacity(LiquidGlassTokens.tintOpacity))
    }

    private var alertForeground: Color {
        model.alert == .red ? .red : .orange
    }

    private func segmentColor(_ segment: HeaderQuotaSegment) -> Color {
        switch segment.state {
        case .live, .critical:
            quotaBrandColors(segment.id).first ?? .accentColor
        case .stale, .unknown:
            .secondary.opacity(0.45)
        }
    }
}

private enum HeaderQuotaDateFormatters {
    static let tooltip: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_Hant_TW")
        formatter.dateFormat = "M/d HH:mm"
        return formatter
    }()

    static let compact: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_Hant_TW")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
}
