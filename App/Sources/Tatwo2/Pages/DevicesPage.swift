// 照搬自 Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac/DevicesPage.swift；改動 2 行（原因：新增來源標頭；移除舊 TatwoDomainContracts import，改用同名 Facade 型別）
import SwiftUI

// W77 consistency table plus W83's explicitly initiated handoff.

struct DevicesPage: View {
    @ObservedObject private var themeStore = TatwoThemeStore.shared
    @ObservedObject private var chatModel: ChatPageModel
    private let deviceSnapshotProvider: any DomainDeviceSnapshotProvider

    init(
        chatModel: ChatPageModel,
        deviceSnapshotProvider: any DomainDeviceSnapshotProvider =
            TatwoDevicesCompositionRoot.makeProvider()
    ) {
        _chatModel = ObservedObject(wrappedValue: chatModel)
        self.deviceSnapshotProvider = deviceSnapshotProvider
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            DeviceConsistencyPanel()
            PrimaryTransferPanel()
        }
    }
}

/// Also used by the synthetic screenshot; every label comes from device.json.
struct PrimaryTransferStatusView: View {
    let record: PrimaryTransfer.Record
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(record.summary).font(.headline)
                .foregroundStyle(record.complete ? Color.green : Color.orange)
            Text("① epoch \(record.oldEpoch) → \(record.epoch)：\(record.epochComplete ? "已完成" : "等待設備讀回")")
            Text("② 憲法正本：\(record.constitutionComplete ? "已遷移" : record.constitution ? "切換中，待兩端讀回" : "仍在舊主設備")")
            Text(record.sourceRoot).font(.caption).textSelection(.enabled)
            Text("③ GBrain：\(record.brain.label)\(record.brainComplete ? "（已驗證）" : "（未完成兩端驗證）")")
            Text("頁數：舊 \(record.sourcePages.map(String.init) ?? "—") ／新 \(record.targetPages.map(String.init) ?? "—")")
                .font(.caption)
            Text("④ 發行能力：\(record.releaseChecked ? record.release.label : "尚未檢查")")
            if record.releaseChecked && record.acknowledgedRevision < record.releaseRevision {
                Text("發行能力檢查結果待兩端讀回").font(.caption)
            }
            if !record.missingDependencies.isEmpty {
                Text("缺少：" + record.missingDependencies.joined(separator: "、")).font(.caption)
            }
            Text("兩端讀回：\(record.acknowledgedRevision == record.revision ? "已同步" : "待同步，可重試") · 版本 \(record.revision)")
                .font(.caption)
        }
    }
}

struct PrimaryTransferPanel: View {
    private let previewOnly: Bool
    @State private var identity: DeviceIdentity?
    @State private var peers: [DeviceRecord] = []
    @State private var target = ""
    @State private var signingName = ""
    @State private var brain = PrimaryTransfer.Brain.migrating
    @State private var message = ""
    @State private var busy = false
    @State private var primaryOnline = false
    @State private var confirming = false

    init(preview: DeviceIdentity? = nil) {
        previewOnly = preview != nil
        _identity = State(initialValue: preview)
        _primaryOnline = State(initialValue: preview?.role == .primary)
        _signingName = State(initialValue: preview?.transfer?.signingName ?? "")
    }

    private var coordinator: Bool {
        identity?.transfer?.from == identity?.deviceID && identity?.transfer != nil
    }
    var body: some View {
        GroupBox("移交主權") {
            VStack(alignment: .leading, spacing: 12) {
                Text("四項分開驗收；不自動搬 GBrain，不匯出任何憑證。").font(.caption)
                if let record = identity?.transfer {
                    PrimaryTransferStatusView(record: record)
                }
                if !primaryOnline {
                    Text("現任主設備須在線才能移交").foregroundStyle(.orange)
                }
                if identity?.role == .primary || coordinator {
                    TextField("與現任主設備相同的簽章身分名稱", text: $signingName)
                        .textFieldStyle(.roundedBorder)
                }
                if identity?.role == .primary {
                    Picker("新主設備", selection: $target) {
                        Text("請選擇").tag("")
                        ForEach(peers) { Text($0.name).tag($0.id) }
                    }
                    Button("① 移交 epoch…") { confirming = true }
                        .disabled(busy || !primaryOnline || target.isEmpty)
                    if let record = identity?.transfer, record.to == identity?.deviceID {
                        Button("移交回原主設備…") {
                            target = record.from; signingName = record.signingName; confirming = true
                        }.disabled(busy || !primaryOnline || !record.epochComplete)
                    }
                }
                if coordinator {
                    Text("請在本頁繼續分項驗收；移交回來須由新主設備發起。").font(.caption)
                    if identity?.transfer?.committed == false && identity?.transfer?.previousTransferID == nil {
                        Button("取消尚未遞增的移交（恢復一般派發）") {
                            run { try DeviceDispatch.shared.cancelPreparedTransfer() }
                        }.disabled(busy)
                    }
                    Button("② 比對全部雜湊並切換正本派發來源") {
                        run { try DeviceDispatch.shared.updateTransfer(constitution: true) }
                    }.disabled(busy || !primaryOnline || identity?.transfer?.epochComplete != true)
                    Picker("③ GBrain", selection: $brain) {
                        ForEach(PrimaryTransfer.Brain.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    DisclosureGroup("匯出／匯入步驟（手動操作）") {
                        ForEach(PrimaryTransfer.migrationSteps, id: \.self) { Text($0).font(.caption) }
                    }
                    Button("驗證 GBrain 健康與頁數") {
                        let selected = brain
                        run { try DeviceDispatch.shared.updateTransfer(brain: selected) }
                    }.disabled(busy || !primaryOnline || identity?.transfer?.constitutionComplete != true)
                    Button("④ 檢查同名簽章身分與打包依賴") {
                        let name = signingName
                        run { try DeviceDispatch.shared.updateTransfer(release: true, signingName: name) }
                    }.disabled(busy || !primaryOnline || identity?.transfer?.constitutionComplete != true)
                }
                HStack {
                    Button("重新檢查／重試同步") { run { DeviceDispatch.shared.synchronize() } }.disabled(busy)
                    if busy { ProgressView().controlSize(.small) }
                }
                if !message.isEmpty { Text(message).font(.caption).textSelection(.enabled) }
            }.padding(8)
        }
        .confirmationDialog("移交主權給所選設備？", isPresented: $confirming) {
            Button("確認移交（epoch 將遞增）") {
                let destination = target, name = signingName
                run { try DeviceDispatch.shared.beginTransfer(to: destination, signingName: name) }
            }
        } message: {
            Text("現任主設備必須配合。完成 epoch 後仍須分別驗收正本、GBrain 與發行能力。")
        }
        .task {
            guard !previewOnly else { return }
            while !Task.isCancelled {
                await refresh()
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
    }
    private func refresh() async {
        let result = await Task.detached(priority: .utility) {
            let dispatch = DeviceDispatch.shared
            let identity = try? dispatch.identity()
            let peers = dispatch.registry.list()
            var online = identity?.role == .primary
            if let primary = peers.first(where: { $0.id == identity?.primaryDeviceID }),
               let remote = try? dispatch.transferIdentity(primary) {
                online = remote.role == .primary && remote.epoch == identity?.epoch
            }
            return (identity, peers, online)
        }.value
        identity = result.0; peers = result.1; primaryOnline = result.2
        if signingName.isEmpty { signingName = result.0?.transfer?.signingName ?? "" }
    }
    private func run(_ action: @escaping @Sendable () throws -> Void) {
        guard !previewOnly else { return }
        busy = true; message = ""
        Task {
            let error = await Task.detached(priority: .utility) {
                do { try action(); return "" } catch { return error.localizedDescription }
            }.value
            message = error.isEmpty ? "已處理；待兩端讀回後更新狀態。" : error
            await refresh(); busy = false
        }
    }
}
