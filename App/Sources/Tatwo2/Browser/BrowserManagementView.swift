// 照搬自 Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac/BrowserManagementView.swift；改動 1 行（原因：加入照搬來源標記）
import SwiftUI

enum TatwoBrowserManagementCopy {
    static let capacityExplanation =
        "超過上限時，會先清掉最久沒用、已封存的資料。"

    static func dataSize(_ bytes: UInt64) -> String {
        let megabytes = Double(bytes) / (1_024 * 1_024)
        if megabytes >= 1_024 {
            let gigabytes = megabytes / 1_024
            return gigabytes.rounded() == gigabytes
                ? "\(Int(gigabytes)) GB"
                : String(format: "%.1f GB", gigabytes)
        }
        return megabytes.rounded() == megabytes
            ? "\(Int(megabytes)) MB"
            : String(format: "%.1f MB", megabytes)
    }

    static func capacityHeadline(
        usedBytes: UInt64?,
        limitBytes: UInt64
    ) -> String {
        let used = usedBytes.map(dataSize) ?? "無法讀取"
        return "瀏覽器資料 \(used)／上限 \(dataSize(limitBytes))"
    }
}

struct TatwoBrowserManagementView: View {
    @ObservedObject var model: ChatPageModel
    @StateObject private var viewModel: TatwoBrowserManagementViewModel
    let onClose: () -> Void

    @State private var pendingConfirmation: PendingConfirmation?
    @State private var pendingDeleteFinal: TatwoBrowserManagementSession?

    init(
        model: ChatPageModel,
        provider: any TatwoBrowserManagementProviding,
        onClose: @escaping () -> Void
    ) {
        self.model = model
        self.onClose = onClose
        _viewModel = StateObject(
            wrappedValue: TatwoBrowserManagementViewModel(
                provider: provider))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            capacityCard

            if let message = viewModel.statusMessage {
                statusCard(message)
            }

            if let error = viewModel.errorMessage {
                failClosedCard(error)
            } else if let sessions = viewModel.snapshot?.sessions,
                      sessions.isEmpty
            {
                emptyState
            } else {
                sessionList
            }
        }
        .onAppear { reload() }
        .onReceive(model.$document) { _ in reload() }
        .confirmationDialog(
            pendingConfirmation?.title ?? "",
            isPresented: Binding(
                get: { pendingConfirmation != nil },
                set: { if !$0 { pendingConfirmation = nil } }),
            titleVisibility: .visible
        ) {
            if let pendingConfirmation {
                Button(
                    pendingConfirmation.confirmationLabel,
                    role: pendingConfirmation.role)
                {
                    let action = pendingConfirmation.action
                    let session = pendingConfirmation.session
                    self.pendingConfirmation = nil
                    if action == .delete {
                        pendingDeleteFinal = session
                    } else {
                        perform(action, session: session)
                    }
                }
                Button("取消", role: .cancel) {
                    self.pendingConfirmation = nil
                }
            }
        } message: {
            Text(pendingConfirmation?.message ?? "")
        }
        .confirmationDialog(
            "再次確認刪除瀏覽資料？",
            isPresented: Binding(
                get: { pendingDeleteFinal != nil },
                set: { if !$0 { pendingDeleteFinal = nil } }),
            titleVisibility: .visible
        ) {
            Button("刪除瀏覽資料", role: .destructive) {
                guard let session = pendingDeleteFinal else { return }
                pendingDeleteFinal = nil
                perform(.delete, session: session)
            }
            Button("取消", role: .cancel) {
                pendingDeleteFinal = nil
            }
        } message: {
            Text(
                "可移到垃圾桶的資料會先移到垃圾桶；其他網站資料會由系統清除。Chat 對話不會被刪除。")
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("工作階段資料")
                    .font(.title3.bold())
                Text("查看每個工作階段留下的登入與網站資料。")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("完成", action: onClose)
                .buttonStyle(.borderedProminent)
                .tint(LiquidGlassTokens.brandAccent)
                .keyboardShortcut(.defaultAction)
        }
    }

    private var capacityCard: some View {
        let used = viewModel.snapshot?.usedBytes
        let limit =
            viewModel.snapshot?.byteLimit
            ?? EmbeddedBrowserSessionPersistenceContract
                .maximumCEFProfileBytes
        let progress = used.map {
            min(1, Double($0) / Double(max(limit, 1)))
        } ?? 0
        return VStack(alignment: .leading, spacing: 8) {
            Label(
                TatwoBrowserManagementCopy.capacityHeadline(
                    usedBytes: used,
                    limitBytes: limit),
                systemImage: "internaldrive")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(used == nil ? .orange : .primary)
            ProgressView(value: progress)
                .tint(
                    progress >= 0.9
                        ? .red
                        : LiquidGlassTokens.brandAccent)
                .accessibilityIdentifier(
                    "browser-management-capacity-bar")
            Text(
                used == nil
                    ? "目前讀不到容量；為了保護資料，管理操作暫時停用。"
                    : TatwoBrowserManagementCopy.capacityExplanation)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(
            Color.secondary.opacity(0.06),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var sessionList: some View {
        ScrollView {
            LazyVStack(spacing: 7) {
                ForEach(viewModel.snapshot?.sessions ?? []) { session in
                    sessionRow(session)
                }
            }
            .padding(.bottom, 8)
        }
        .accessibilityIdentifier("browser-management-session-list")
    }

    private func sessionRow(
        _ session: TatwoBrowserManagementSession
    ) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top, spacing: 10) {
                Image(
                    systemName:
                        session.persistence == .persistent
                            ? "person.crop.circle.badge.checkmark"
                            : "person.crop.circle.badge.clock")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(
                        session.persistence == .persistent
                            ? LiquidGlassTokens.brandAccent
                            : .secondary)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(session.name)
                            .font(.system(size: 12, weight: .semibold))
                            .lineLimit(1)
                        if session.isArchived {
                            Text("已封存")
                                .font(.system(size: 8.5, weight: .bold))
                                .foregroundStyle(.orange)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(
                                    Color.orange.opacity(0.1),
                                    in: Capsule())
                        }
                    }
                    Text(
                        "最後使用 \(session.lastUsedAt.formatted(date: .abbreviated, time: .shortened))"
                    )
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 3) {
                    Text(session.sizeBytes.map(formatBytes) ?? "大小未知")
                        .font(.system(size: 10.5, weight: .semibold))
                    Text(session.persistence.label)
                        .font(.system(size: 9.5))
                        .foregroundStyle(.secondary)
                }
                sessionMoreMenu(session)
            }

            HStack(spacing: 7) {
                if session.currentOriginURL != nil {
                    actionButton(
                        "清這個網站的資料",
                        systemImage: "eraser")
                    {
                        perform(.clearCurrentSite, session: session)
                    }
                }
                actionButton(
                    "清空這個 session 的瀏覽資料",
                    systemImage: "arrow.counterclockwise")
                {
                    pendingConfirmation = PendingConfirmation(
                        action: .reset,
                        session: session)
                }
                Spacer(minLength: 4)
            }
            .disabled(viewModel.activeSessionID != nil)
        }
        .padding(11)
        .background(
            Color.secondary.opacity(0.055),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(alignment: .topTrailing) {
            if viewModel.activeSessionID == session.id {
                ProgressView()
                    .controlSize(.small)
                    .padding(9)
            }
        }
        .accessibilityIdentifier(
            "browser-management-session-\(session.id.uuidString.lowercased())")
    }

    private func sessionMoreMenu(
        _ session: TatwoBrowserManagementSession
    ) -> some View {
        Menu {
            Button {
                perform(.archive, session: session)
            } label: {
                Label("封存", systemImage: "archivebox")
            }
            .disabled(session.isArchived)

            Divider()

            Button(role: .destructive) {
                pendingConfirmation = PendingConfirmation(
                    action: .delete,
                    session: session)
            } label: {
                Label("刪除瀏覽資料…", systemImage: "trash")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(viewModel.activeSessionID != nil)
        .help("更多管理操作")
        .accessibilityLabel("更多管理操作")
        .accessibilityIdentifier(
            "browser-management-more-\(session.id.uuidString.lowercased())")
    }

    private func actionButton(
        _ title: String,
        systemImage: String,
        role: ButtonRole? = nil,
        disabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(role: role, action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 10.5, weight: .medium))
        }
        .buttonStyle(.borderless)
        .disabled(disabled)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "globe.desk")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("目前沒有可管理的瀏覽資料")
                .font(.system(size: 12, weight: .semibold))
            Text("使用內建瀏覽器後，工作階段的資料會顯示在這裡。")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func statusCard(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "checkmark.circle")
                .foregroundStyle(LiquidGlassTokens.brandAccent)
            Text(message)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(9)
        .background(
            LiquidGlassTokens.brandAccent.opacity(0.08),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func failClosedCard(_ message: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.shield.fill")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(.orange)
            Text(message)
                .font(.system(size: 11.5, weight: .semibold))
                .multilineTextAlignment(.center)
            Button("重新讀取", action: reload)
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func reload() {
        viewModel.reload(descriptors: sessionDescriptors)
    }

    private var sessionDescriptors:
        [TatwoBrowserManagementSessionDescriptor]
    {
        let threads =
            model.document.threads
            + model.document.projects.flatMap(\.threads)
        return threads.map {
            TatwoBrowserManagementSessionDescriptor(
                sessionID: $0.id,
                name: $0.title,
                updatedAt: $0.updatedAt,
                isArchived: $0.isArchived)
        }
    }

    private func perform(
        _ action: TatwoBrowserManagementAction,
        session: TatwoBrowserManagementSession
    ) {
        Task { @MainActor in
            let didExecute = await viewModel.performAction(
                action,
                sessionID: session.id
            ) {
                await model.performBrowserManagementAction(
                    action,
                    session: session)
            }
            if didExecute {
                reload()
            }
        }
    }

    private func formatBytes(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(
            fromByteCount: Int64(clamping: bytes),
            countStyle: .binary)
    }

    private struct PendingConfirmation: Identifiable {
        let action: TatwoBrowserManagementAction
        let session: TatwoBrowserManagementSession

        var id: String {
            "\(session.id.uuidString)-\(action)"
        }

        var title: String {
            switch action {
            case .reset:
                "清空這個 session 的瀏覽資料？"
            case .delete:
                "刪除這個 session 的瀏覽資料？"
            default:
                ""
            }
        }

        var message: String {
            switch action {
            case .reset:
                "Cookie、登入狀態、網站儲存與瀏覽記錄會清除；Chat 對話不受影響。"
            case .delete:
                "這會刪除瀏覽資料，但不會刪除 Chat 對話。下一步仍會再次確認。"
            default:
                ""
            }
        }

        var confirmationLabel: String {
            action == .delete ? "繼續" : "確認清空"
        }

        var role: ButtonRole? {
            action == .delete ? .destructive : nil
        }
    }
}
