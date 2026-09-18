// 照搬自 Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac/DeviceSyncLeafViews.swift；改動 2 行（原因：新增來源標頭；移除舊 TatwoUltraworkCore import，改用同名 Facade 型別）
import SwiftUI

struct DevicesSectionHeader: View {
    @ObservedObject private var themeStore = TatwoThemeStore.shared
    let index: String
    let title: String
    var actionTitle: String? = nil
    var actionEnabled: Bool = true
    var onAction: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 8) {
            Text(index)
                .font(.caption.weight(.bold).monospacedDigit())
                .foregroundStyle(LiquidGlassTokens.brandAccent)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(
                    LiquidGlassTokens.brandAccent.opacity(LiquidGlassTokens.chipFillOpacity),
                    in: Capsule()
                )
            Text(title)
                .font(.system(size: 15, weight: .bold, design: .rounded))
            Spacer(minLength: 0)
            if let actionTitle, let onAction {
                Button(action: onAction) {
                    Text(actionTitle)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(LiquidGlassTokens.brandAccent)
                .disabled(!actionEnabled)
                .opacity(actionEnabled ? 0.72 : 0.40)
            }
        }
    }
}

struct DevicesInclusionPill: View {
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            EmptyView()
        }
        .labelsHidden()
        .toggleStyle(.switch)
        .controlSize(.mini)
        .accessibilityLabel(isOn ? "納入本輪動作" : "不納入本輪動作")
        .accessibilityValue(isOn ? "開" : "關")
    }
}

struct DeviceIdentityCard: View {
    @ObservedObject private var themeStore = TatwoThemeStore.shared
    let model: DevicesIdentityCardModel
    let transferPending: Bool
    let onTransferPrimary: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 8) {
                Circle()
                    .fill(connectionColor)
                    .frame(width: 8, height: 8)
                    .accessibilityHidden(true)
                Text(model.displayName)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                localityChip
                Spacer(minLength: 4)
                Image(systemName: model.isPrimary ? "crown.fill" : "crown")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(model.isPrimary ? Color.yellow : Color.secondary)
                    .help(model.isPrimary ? "主設備" : "副設備")
                    .accessibilityLabel(model.isPrimary ? "主設備" : "副設備")
            }
            Text(model.hardwareLine)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .opacity(model.isInventoryStale ? 0.4 : 1)
            if let updated = model.inventoryUpdatedLabel {
                Text(updated)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            HStack(spacing: 8) {
                Text("App \(model.appVersion ?? DevicesPagePresentation.unknownVersion)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                Text(model.connection.label)
                    .font(.caption2)
                    .foregroundStyle(connectionColor)
                Spacer(minLength: 4)
                if let onTransferPrimary {
                    Button(action: onTransferPrimary) {
                        if transferPending {
                            ProgressView().controlSize(.mini)
                        } else {
                            Text("轉移主權")
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .tint(LiquidGlassTokens.brandAccent)
                    .disabled(transferPending)
                    .opacity(0.72)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .liquidGlassSurface(cornerRadius: LiquidGlassTokens.radiusChip)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(model.displayName)，\(model.localityLabel)，\(model.isPrimary ? "主設備" : "副設備")，\(model.connection.label)"
        )
    }

    private var localityChip: some View {
        Text(model.localityLabel)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                LiquidGlassTokens.tint.opacity(LiquidGlassTokens.chipFillOpacity),
                in: Capsule()
            )
            .foregroundStyle(.secondary)
    }

    private var connectionColor: Color {
        switch model.connection {
        case .connected: .green
        case .syncing: LiquidGlassTokens.brandAccent
        case .offline: .orange
        case .unknown: .secondary
        }
    }
}

struct DeviceVersionRow: View {
    let model: DevicesVersionRowModel
    @Binding var isIncluded: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.deviceName)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                Text("App \(model.appVersion)  ·  head \(model.releaseHead)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let lastCheckLabel = model.lastCheckLabel {
                    Text(lastCheckLabel)
                        .font(.caption2)
                        .foregroundStyle(model.isFailed ? Color.red : Color.secondary.opacity(0.72))
                }
            }
            Spacer(minLength: 8)
            if model.isChecking {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("\(model.deviceName) 更新中")
            } else {
                DevicesInclusionPill(isOn: $isIncluded)
            }
        }
        .padding(.vertical, 3)
    }
}

struct DeviceDataDeviceRow: View {
    let model: DevicesDataDeviceRowModel
    @Binding var isIncluded: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.deviceName)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                if let statusLabel = model.statusLabel {
                    Text(statusLabel)
                        .font(.caption2)
                        .foregroundStyle(model.isFailed ? Color.red : Color.secondary.opacity(0.72))
                }
            }
            Spacer(minLength: 8)
            if model.isSyncing {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("\(model.deviceName) 同步中")
            } else {
                DevicesInclusionPill(isOn: $isIncluded)
            }
        }
        .padding(.vertical, 3)
    }
}

struct DeviceCLIVersionInfoRow: View {
    let model: DevicesCLIVersionInfoModel

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.titleZh)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                Text(model.plainZh)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Text("尚無運輸")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(model.titleZh)，資訊列，尚無運輸")
    }
}

struct DeviceDataModuleRow: View {
    let model: DevicesDataModuleRowModel
    let isReasonExpanded: Bool
    let onToggle: (Bool) -> Void
    let onToggleReason: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.titleZh)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                    Text(model.plainZh)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .opacity(model.excluded ? 0.45 : 1)
                Spacer(minLength: 8)
                trailingControl
            }
            if isReasonExpanded, let reason = model.failureReason {
                Text(reason)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(1)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 3)
    }

    @ViewBuilder
    private var trailingControl: some View {
        if model.excluded {
            Text(DevicesPagePresentation.threadsExclusionNote)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        } else if model.isSyncing {
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel("\(model.titleZh) 同步中")
        } else {
            HStack(spacing: 8) {
                if model.isFailed {
                    Button(action: onToggleReason) {
                        Circle()
                            .fill(Color.red)
                            .frame(width: 7, height: 7)
                    }
                    .buttonStyle(.plain)
                    .help(isReasonExpanded ? "收合失敗原因" : "顯示失敗原因")
                    .accessibilityLabel("同步失敗")
                }
                Toggle(isOn: Binding(
                    get: { model.enabled },
                    set: { newValue in onToggle(newValue) }
                )) {
                    EmptyView()
                }
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .accessibilityLabel(model.titleZh)
            }
        }
    }
}

struct DevicePressureMetricChip: View {
    @ObservedObject private var themeStore = TatwoThemeStore.shared
    let label: String
    let value: String
    var tint: Color = .secondary

    var body: some View {
        HStack(spacing: 4) {
            Text(label)
                .foregroundStyle(.tertiary)
            Text(value)
                .foregroundStyle(tint)
        }
        .font(.caption2.weight(.semibold))
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(
            LiquidGlassTokens.tint.opacity(LiquidGlassTokens.chipFillOpacity),
            in: Capsule()
        )
    }
}


// MARK: - W77 consistency table (read-only)

struct DeviceConsistencyPanel: View {
    @StateObject private var model = DeviceConsistencyModel()
    @State private var diff: DeviceConsistencyDiffSheet?
    @State private var endpointDevices: [DeviceRecord] = []
    @State private var dispatchReceipts: [String: DeviceDispatch.Receipt] = [:]
    @State private var inbox: [DeviceInbox.Branch] = []
    @State private var submissionMessage = ""
    @State private var submissionStatus = ""
    @State private var submitting = false
    @State private var jobs: [JobQueue.Row] = []
    @State private var jobsExpanded = false
    private let columns: [(DeviceStatusColumn, String, CGFloat)] = [
        (.identity, "設備／角色", 190), (.connection, "連線", 132), (.app, "App 版本", 144),
        (.code, "程式碼", 180), (.constitution, "憲法", 152), (.rules, "規則產物", 154), (.gbrain, "GBrain", 112),
        (.capacity, "容量／佇列", 208),
    ]

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("一致性面板").font(.headline)
                    Spacer()
                    if model.refreshing { ProgressView().controlSize(.small) }
                    Button("重新檢查") { Task { await model.refresh() } }
                        .disabled(model.refreshing)
                }
                TimelineView(.periodic(from: .now, by: 5)) { context in
                    table(now: context.date)
                }
                ForEach(model.rows) { row in
                    if let transfer = row.probe.snapshot?.identity.value?.transfer {
                        DisclosureGroup("\(row.probe.snapshot?.identity.value?.name ?? row.addressLabel) · \(transfer.summary)") {
                            PrimaryTransferStatusView(record: transfer)
                        }
                    }
                }
                ForEach(dispatchReceipts.keys.sorted(), id: \.self) { id in
                    if let receipt = dispatchReceipts[id] {
                        Text("\(id.prefix(8)) · \(receipt.phase == "timeout" ? "逾時" : receipt.phase) · 讀回 \(receipt.hashes.count) 檔"
                             + (receipt.detail.map { " · \($0)" } ?? ""))
                            .font(.caption).foregroundStyle(receipt.phase == "converged" ? Color.green : Color.orange)
                            .textSelection(.enabled)
                    }
                }
                DisclosureGroup(isExpanded: $jobsExpanded) {
                    if jobs.isEmpty {
                        Text("沒有施工工作").font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(jobs) { job in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(job.kind).font(.caption.monospaced()).frame(width: 78, alignment: .leading)
                            Text(job.branch.split(separator: "/").last.map(String.init) ?? job.branch)
                                .font(.caption).frame(width: 150, alignment: .leading)
                            Text(DeviceJobPresentation.status(job.status)).font(.caption)
                                .foregroundStyle(DeviceJobPresentation.tint(job.status))
                            Text((job.startedAt ?? "—") + " → " + (job.endedAt ?? "—"))
                                .font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
                            Text(job.exit.map { "exit \($0)" } ?? (job.reason ?? ""))
                                .font(.caption2).foregroundStyle(.secondary)
                        }.textSelection(.enabled)
                    }
                } label: {
                    Text("施工工作（\(jobs.count)）").font(.headline)
                }
                if OSDocuments.isPrimary {
                    Text("收件箱").font(.headline)
                    if inbox.isEmpty { Text("沒有待整合分支").foregroundStyle(.secondary) }
                    ForEach(inbox) { item in
                        VStack(alignment: .leading) {
                            Text(item.branch).font(.caption.monospaced())
                            Text(item.message).font(.callout)
                            Text("來源 \(item.sender) · \(item.commit.prefix(12))").font(.caption)
                        }.textSelection(.enabled)
                    }
                } else {
                    HStack {
                        TextField("提交說明（只送已提交的目前分支，不送 GitHub）", text: $submissionMessage)
                        Button("提交給主設備") {
                            submitting = true
                            let message = submissionMessage
                            Task {
                                let result = await Task.detached {
                                    do { return try DeviceInbox.shared.submit(message: message) }
                                    catch { return error.localizedDescription }
                                }.value
                                submissionStatus = result; submitting = false
                            }
                        }.disabled(submitting || submissionMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                if !submissionStatus.isEmpty { Text(submissionStatus).font(.caption).textSelection(.enabled) }
            }
        }
        .task {
            while !Task.isCancelled {
                await model.refresh()
                let dispatchState = await Task.detached {
                    (DeviceDispatch.shared.receipts(), DeviceInbox.shared.branches(), DeviceRegistry().list(),
                     JobQueue.shared.rows())
                }.value
                dispatchReceipts = dispatchState.0
                inbox = dispatchState.1
                endpointDevices = dispatchState.2
                jobs = dispatchState.3
                try? await Task.sleep(nanoseconds: 10_000_000_000)
            }
        }
        .sheet(item: $diff) { sheet in
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(sheet.title).font(.headline)
                    Spacer()
                    Button("關閉") { diff = nil }
                }
                ScrollView([.vertical, .horizontal]) {
                    Text(sheet.text).font(.system(.body, design: .monospaced))
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(20).frame(minWidth: 700, idealWidth: 900, minHeight: 460, idealHeight: 650)
        }
    }

    private func table(now: Date) -> some View {
        let local = model.rows.first(where: \.local)?.probe.snapshot
        let primary = DeviceStatusPolicy.primary(local: local, probes: model.rows.map(\.probe), now: now)
        return ScrollView(.horizontal) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 16) {
                    ForEach(columns, id: \.0) { column in
                        Text(column.1).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            .frame(width: column.2, alignment: .leading)
                    }
                }.padding(.vertical, 8)
                ForEach(model.rows) { row in
                    Divider()
                    HStack(alignment: .top, spacing: 16) {
                        ForEach(columns, id: \.0) { column in
                            let cell = DeviceConsistencyPresentation.cell(column: column.0, row: row, primary: primary, now: now)
                            VStack(alignment: .leading, spacing: 5) {
                                HStack(alignment: .firstTextBaseline, spacing: 5) {
                                    Circle().fill(color(cell.light)).frame(width: 7, height: 7)
                                        .accessibilityLabel(label(cell.light))
                                    Text(cell.title).font(.callout.weight(column.0 == .identity ? .semibold : .regular))
                                }
                                if row.local && column.0 == .identity {
                                    Text("本機").font(.caption2).foregroundStyle(.secondary)
                                }
                                if !cell.detail.isEmpty {
                                    Text(cell.detail).font(.caption).foregroundStyle(.secondary)
                                }
                                Text(cell.acquiredAt, style: .time).font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
                                if column.0 == .constitution || column.0 == .rules {
                                    Button("看差異") { showDiff(column: column.0, local: local, primary: primary) }
                                        .buttonStyle(.link)
                                        .disabled(!canDiff(column: column.0, local: local, primary: primary, now: now))
                                }
                                if cell.light == .yellow {
                                    Button("對齊") {
                                        DeviceDispatch.shared.align(
                                            targetDeviceID: row.local ? nil : row.probe.snapshot?.identity.value?.deviceID,
                                            regenerateRules: !OSDocuments.isPrimary)
                                        submissionStatus = "已要求派發／拉取；讀回一致後依 W68 檢查規則產物並保留手改，App 更新請到更新頁檢查。"
                                    }.buttonStyle(.link)
                                }
                            }
                            .frame(width: column.2, alignment: .leading)
                            .help(cell.reason.map(DeviceConsistencyPresentation.reason) ?? "取得時間：\(cell.acquiredAt.formatted())")
                        }
                    }.padding(.vertical, 14)
                    if !row.local, let device = endpointDevices.first(where: {
                        "\($0.user)@\($0.host):\($0.sshPort)" == row.id
                    }) {
                        DeviceEndpointsRow(device: device)
                        // 兩把指紋與來源；缺一把就代表對應的路徑（隧道／RPC）會被擋。
                        Text(device.fingerprintSummary)
                            .font(.footnote)
                            .foregroundStyle(
                                device.hostKeyFingerprint == nil || device.clientKeyFingerprint == nil
                                    ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private func canDiff(column: DeviceStatusColumn, local: DeviceStatusSnapshot?, primary: DeviceStatusSnapshot?, now: Date) -> Bool {
        guard let local, let primary else { return false }
        if column == .rules {
            return local.rules.value?.runtime.value?.text != nil && primary.rules.value?.runtime.value?.text != nil
                && DeviceStatusPolicy.fresh(local.rules.acquiredAt, now: now)
                && DeviceStatusPolicy.fresh(primary.rules.acquiredAt, now: now)
        }
        return (local.constitution.value?.text != nil && primary.constitution.value?.text != nil
                || local.skillet.value?.text != nil && primary.skillet.value?.text != nil)
            && DeviceStatusPolicy.fresh(local.constitution.acquiredAt, now: now)
            && DeviceStatusPolicy.fresh(primary.constitution.acquiredAt, now: now)
    }

    private func showDiff(column: DeviceStatusColumn, local: DeviceStatusSnapshot?, primary: DeviceStatusSnapshot?) {
        let text: String
        if column == .rules {
            text = DeviceStatusDiff.text(local: local?.rules.value?.runtime.value?.text,
                                         primary: primary?.rules.value?.runtime.value?.text)
        } else {
            text = "os.md\n" + DeviceStatusDiff.text(local: local?.constitution.value?.text, primary: primary?.constitution.value?.text)
                + "\n\nskillet.md\n" + DeviceStatusDiff.text(local: local?.skillet.value?.text, primary: primary?.skillet.value?.text)
        }
        diff = .init(title: "\(column == .rules ? "規則產物" : "憲法") · 本機與主設備（唯讀）", text: text)
    }

    private func color(_ light: DeviceStatusLight) -> Color {
        switch light { case .green: return .green; case .yellow: return .orange; case .red: return .red; case .gray: return .gray }
    }
    private func label(_ light: DeviceStatusLight) -> String {
        switch light { case .green: return "符合政策"; case .yellow: return "待確認"; case .red: return "不符合政策"; case .gray: return "未知或過期" }
    }
}

/// W95 施工工作清單的字面呈現；狀態字串由主設備佇列檔決定，這裡只翻譯不判斷。
enum DeviceJobPresentation {
    static func status(_ value: String) -> String {
        ["queued": "排隊中", "running": "執行中", "done": "完成", "failed": "失敗"][value] ?? value
    }
    static func tint(_ value: String) -> Color {
        switch value {
        case "done": return .green
        case "failed": return .red
        case "running": return .orange
        default: return .secondary
        }
    }
}

private struct DeviceConsistencyDiffSheet: Identifiable {
    let id = UUID()
    let title: String
    let text: String
}
