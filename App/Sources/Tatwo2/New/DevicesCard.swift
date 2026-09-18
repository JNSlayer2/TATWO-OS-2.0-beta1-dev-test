// 2.0 新畫面（不是照搬）：遠端系統 R1／R2 的設定頁「設備」卡。白話：家裡的 mini 是主機，MacBook 是遙控器。
// 新畫面一律放 New/；Facade 禁自畫 View。
import SwiftUI

/// 設定頁「設備」：配對碼（主機端）、加入主機（副機端）、已配對清單、遙控模式開關。
struct DevicesCard: View {
    @ObservedObject var model: ChatPageModel
    @State private var hostField = ""
    @State private var portField = ""
    @State private var codeField = ""
    @State private var nameField = Host.current().localizedName ?? "這台"
    @State private var updateOffers: [String: [String: PeerUpdateEntry]] = [:]
    /// W98：展開哪幾台（只在這個畫面存活，不持久化）。
    @State private var expandedDevices: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("設備")
                .font(.title3.bold())

            PrimaryTransferPanel()

            // 主機端：出一組碼
            VStack(alignment: .leading, spacing: 8) {
                Text("讓另一台加入這台（這台當主機）")
                    .font(.headline)
                if let window = model.pairingWindow {
                    let listen = model.pairingListenAddress ?? "—"
                    HStack(spacing: 12) {
                        Text(window.code)
                            .font(.system(size: 28, weight: .bold, design: .monospaced))
                            .textSelection(.enabled)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("在另一台輸入 \(listen)")
                                .font(.footnote)
                            Text("5 分鐘內有效、只能用一次；\(Self.remaining(window.expiresAt)) 後失效")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("取消") { model.cancelPairingWindow() }
                            .buttonStyle(.bordered)
                    }
                } else {
                    HStack {
                        Text("按下去會出一組 6 碼，對方輸入後它的鑰匙就進這台的名單。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("產生配對碼") { model.startPairingWindow() }
                            .buttonStyle(.borderedProminent)
                    }
                }
            }

            Divider()

            // 副機端：加入主機
            VStack(alignment: .leading, spacing: 8) {
                Text("把這台加到另一台主機（這台當遙控器）")
                    .font(.headline)
                HStack(spacing: 8) {
                    TextField("主機位址（例：192.0.2.10 或 device.example）", text: $hostField)
                        .textFieldStyle(.roundedBorder)
                    TextField("配對埠", text: $portField)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                    TextField("6 碼", text: $codeField)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                    TextField("這台叫什麼", text: $nameField)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 120)
                    Button("加入") {
                        let port = Int(portField) ?? 0
                        model.pairWithHost(host: hostField.trimmingCharacters(in: .whitespaces),
                                           port: port,
                                           code: codeField.trimmingCharacters(in: .whitespaces),
                                           name: nameField)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(hostField.isEmpty || codeField.count != 6)
                }
                if let pairMessage = model.pairingClientMessage {
                    Text(pairMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            // 已配對清單
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("已配對（\(model.devices.count)）")
                        .font(.headline)
                    Spacer()
                    if let remote = model.remoteMode {
                        Text("遙控中：\(remote.name)")
                            .font(.footnote.weight(.semibold))
                        Button("回到本機") { model.exitRemoteMode() }
                            .buttonStyle(.bordered)
                    }
                }
                if model.devices.isEmpty {
                    Text("還沒有配對任何設備。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.devices) { device in
                        deviceRow(device)
                    }
                }
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task(id: model.devices) {
            updateOffers = [:]
            for offer in await PeerUpdateSource.discover(model.devices) {
                updateOffers[offer.device.id] = offer.entries
            }
        }
    }

    /// W98：一台設備一列，收法照設定 › Computer Use 的列（左 chevron、標題 13 semibold、副標 11.5）。
    /// 收合只露設備名／狀態／`user@host`；指紋、連線路徑、時間與操作都收進展開區。展開狀態不持久化。
    @ViewBuilder
    private func deviceRow(_ device: DeviceRecord) -> some View {
        let isExpanded = expandedDevices.contains(device.id)
        let isOnline = RemoteDevicePresentation.isOnline(device, sections: model.remoteSidebarSections)
        let update = PeerUpdateSource.summary(updateOffers[device.id] ?? [:])
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .frame(width: 10)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(device.name).font(.system(size: 13, weight: .semibold))
                        badge(isOnline ? "在線" : "離線", color: isOnline ? .green : .secondary)
                        // 沒有可提供的更新就不占位（PeerUpdateSource 會回「可提供更新：無」）。
                        if !update.hasSuffix("無") {
                            badge(update, color: .orange)
                        }
                    }
                    Text("\(device.user)@\(device.host):\(device.sshPort)")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.18)) {
                    if isExpanded { expandedDevices.remove(device.id) } else { expandedDevices.insert(device.id) }
                }
            }
            .accessibilityAddTraits(.isButton)
            .accessibilityHint(isExpanded ? "收起" : "展開指紋、連線路徑與操作")

            if isExpanded {
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    // 隧道識別（建隧道用）與簽章識別（驗 RPC 簽章用）分開顯示，缺哪把看得出來。
                    Text(device.fingerprintSummary)
                        .font(.footnote)
                        .foregroundStyle(
                            device.hostKeyFingerprint == nil || device.clientKeyFingerprint == nil
                                ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                        .fixedSize(horizontal: false, vertical: true)
                    DeviceEndpointsRow(device: device) { updated in
                        if let index = model.devices.firstIndex(where: { $0.id == updated.id }) {
                            model.devices[index] = updated
                        }
                    }
                    Text("加入 \(Self.stamp(device.addedAt))・最近 \(Self.stamp(device.lastSeenAt))")
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                    HStack(spacing: 8) {
                        if model.remoteMode?.id != device.id {
                            // W98：設備頁不再是遙控入口，這顆只把側欄「專案」區打開並跳進那個項目。
                            Button("遠端設備專案") {
                                model.requestSidebarProjectsExpanded()
                                _ = model.enterRemoteMode(device)
                            }
                            .buttonStyle(.bordered)
                            .help("到左側「專案」區的「遠端設備（\(device.name)）」，在那台上工作")
                        }
                        Button("移除") { model.removeDevice(device.id) }
                            .buttonStyle(.bordered)
                        Spacer()
                    }
                }
                .padding(.horizontal, 14)
                .padding(.leading, 18)
                .padding(.vertical, 11)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.secondary.opacity(0.06))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                }
        )
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.12), in: Capsule())
    }

    private static func remaining(_ date: Date) -> String {
        let s = max(0, Int(date.timeIntervalSinceNow))
        return "\(s / 60) 分 \(s % 60) 秒"
    }

    private static func stamp(_ date: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "MM-dd HH:mm"; return f.string(from: date)
    }
}

/// W98：設備頁與側欄共用的呈現規則（只看既有欄位，不新增資料、不改信任）。
enum RemoteDevicePresentation {
    /// 在線＝目前有連上的遠端工作階段，或最近 10 分鐘內成功連過（`lastSeenAt` 只在連線成功時更新）。
    static func isOnline(_ device: DeviceRecord, sections: [RemoteSidebarSection], now: Date = Date()) -> Bool {
        if sections.first(where: { $0.deviceID == device.id })?.isOnline == true { return true }
        return now.timeIntervalSince(device.lastSeenAt) < 600
    }

    /// 跟資料夾專案區別：mini 用 macmini，其餘用 desktopcomputer。
    static func icon(_ device: DeviceRecord) -> String {
        device.name.lowercased().contains("mini") ? "macmini" : "desktopcomputer"
    }
}

/// Shared by both device surfaces; editing only changes routes, never pairing trust.
struct DeviceEndpointsRow: View {
    let device: DeviceRecord
    var changed: (DeviceRecord) -> Void = { _ in }
    @State private var current: DeviceRecord?
    @State private var input = ""
    @State private var kind: DeviceEndpoint.Kind = .lan
    @State private var message = ""
    @State private var busy = false

    var body: some View {
        let record = current ?? device
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(record.endpoints, id: \.self) { endpoint in
                    HStack {
                        Text("\(Self.kindLabel(endpoint.kind)) · \(endpoint.label)").textSelection(.enabled)
                        Button("停用這條路（可還原）") { update(endpoint, retire: true) }.disabled(busy)
                    }
                }
                ForEach(record.retiredEndpoints, id: \.self) { endpoint in
                    Text("已停用 · \(endpoint.label)").foregroundStyle(.secondary)
                }
                HStack {
                    Picker("類型", selection: $kind) {
                        Text("區網 IP").tag(DeviceEndpoint.Kind.lan)
                        Text("隧道").tag(DeviceEndpoint.Kind.tunnel)
                        Text("SSH 別名").tag(DeviceEndpoint.Kind.alias)
                    }.frame(maxWidth: 160)
                    TextField(Self.placeholder(kind), text: $input)
                    Button("加一條連線路徑") {
                        do { update(try DeviceEndpoint.parse(Self.normalized(input, kind: kind), kind: kind), retire: false) }
                        catch { message = error.localizedDescription }
                    }.disabled(busy || input.isEmpty)
                }
                // 白話說明：三種路各是什麼、照什麼順序試（順序本身沒改，見 DeviceRecord.orderedEndpoints）。
                Text("區網＝同一 Wi-Fi 直連；隧道＝出門在外走 Cloudflare；SSH 別名＝用 ~/.ssh/config 的設定。依區網→隧道→別名順序嘗試。")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !message.isEmpty { Text(message).foregroundStyle(.orange) }
            }
        } label: {
            TimelineView(.periodic(from: .now, by: 5)) { context in
                let fresh = (0...60).contains(context.date.timeIntervalSince(record.lastSeenAt))
                Text("連線路徑 \(record.endpoints.count) · " + (record.lastEndpoint.map {
                    fresh ? "最近可用 \($0.label)" : "目前未知（上次 \($0.label)）"
                } ?? "目前未知"))
            }
        }
        .font(.caption)
        .task(id: device.id) {
            while !Task.isCancelled {
                let id = device.id
                current = await Task.detached { DeviceRegistry().list().first { $0.id == id } }.value
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
    }

    /// 只是顯示用的白話名，存進去的還是原本的 `DeviceEndpoint.Kind`。
    private static func kindLabel(_ kind: DeviceEndpoint.Kind) -> String {
        switch kind {
        case .lan: return "區網 IP"
        case .tunnel: return "隧道"
        case .alias: return "SSH 別名"
        }
    }

    private static func placeholder(_ kind: DeviceEndpoint.Kind) -> String {
        kind == .alias ? "~/.ssh/config 裡的名稱" : "host[:port]（例：192.0.2.10:22）"
    }

    /// 選了「SSH 別名」就不用再自己打 `alias:` 前綴；解析規則本身沒動。
    private static func normalized(_ input: String, kind: DeviceEndpoint.Kind) -> String {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard kind == .alias, !text.hasPrefix("alias:") else { return text }
        return "alias:" + text
    }

    private func update(_ endpoint: DeviceEndpoint, retire: Bool) {
        busy = true
        let id = device.id
        Task {
            let result = await Task.detached { () -> Result<DeviceRecord, Error> in
                Result { try DeviceRegistry().updateEndpoint(id: id, endpoint: endpoint, retire: retire) }
            }.value
            switch result {
            case .success(let record): current = record; changed(record); input = ""; message = ""
            case .failure(let error): message = error.localizedDescription
            }
            busy = false
        }
    }
}
