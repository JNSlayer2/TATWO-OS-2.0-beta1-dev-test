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
                        HStack(alignment: .top, spacing: 10) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(device.name)
                                    .font(.subheadline.weight(.medium))
                                Text(PeerUpdateSource.summary(updateOffers[device.id] ?? [:]))
                                    .font(.footnote).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                Text("\(device.user)@\(device.host):\(device.sshPort) · 指紋 \(device.publicKeyFingerprint.prefix(16))…")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                DeviceEndpointsRow(device: device) { updated in
                                    if let index = model.devices.firstIndex(where: { $0.id == updated.id }) {
                                        model.devices[index] = updated
                                    }
                                }
                                Text("加入 \(Self.stamp(device.addedAt))・最近 \(Self.stamp(device.lastSeenAt))")
                                    .font(.footnote)
                                    .foregroundStyle(.tertiary)
                            }
                            Spacer()
                            if model.remoteMode?.id != device.id {
                                Button("遙控它") { _ = model.enterRemoteMode(device) }
                                    .buttonStyle(.bordered)
                                    .help("左列與對話改成這台主機的，送出的話由它跑；離線時回到本機")
                            }
                            Button("移除") { model.removeDevice(device.id) }
                                .buttonStyle(.bordered)
                        }
                        .padding(.vertical, 4)
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

    private static func remaining(_ date: Date) -> String {
        let s = max(0, Int(date.timeIntervalSinceNow))
        return "\(s / 60) 分 \(s % 60) 秒"
    }

    private static func stamp(_ date: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "MM-dd HH:mm"; return f.string(from: date)
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
                        Text("\(endpoint.kind.rawValue) · \(endpoint.label)").textSelection(.enabled)
                        Button("刪除端點（封存）") { update(endpoint, retire: true) }.disabled(busy)
                    }
                }
                ForEach(record.retiredEndpoints, id: \.self) { endpoint in
                    Text("已封存 · \(endpoint.label)").foregroundStyle(.secondary)
                }
                HStack {
                    Picker("類型", selection: $kind) {
                        Text("LAN").tag(DeviceEndpoint.Kind.lan)
                        Text("隧道").tag(DeviceEndpoint.Kind.tunnel)
                    }.frame(maxWidth: 120)
                    TextField("host[:port] 或 alias:名稱", text: $input)
                    Button("新增端點") {
                        do { update(try DeviceEndpoint.parse(input, kind: kind), retire: false) }
                        catch { message = error.localizedDescription }
                    }.disabled(busy || input.isEmpty)
                }
                if !message.isEmpty { Text(message).foregroundStyle(.orange) }
            }
        } label: {
            TimelineView(.periodic(from: .now, by: 5)) { context in
                let fresh = (0...60).contains(context.date.timeIntervalSince(record.lastSeenAt))
                Text("端點 \(record.endpoints.count) · " + (record.lastEndpoint.map {
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
