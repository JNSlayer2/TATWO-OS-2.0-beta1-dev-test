import SwiftUI

/// Presentation only. The caller supplies prepared devices and thread-scoped
/// state, and must revalidate consent against the live controller before acting.
/// Closing this panel does not stop or authorize a device.
struct IPadChatConnectionPanel: View {
    struct Device: Identifiable, Equatable {
        let id: String
        let name: String
    }

    enum Phase: Equatable {
        case choose
        case consent(device: Device, threadID: UUID)
        case connecting, authorizedHere, ownedElsewhere, stopping, stopUnconfirmed
        case failed(String)

        var allowsSelection: Bool {
            switch self {
            case .choose, .failed: return true
            default: return false
            }
        }

        var isBusy: Bool {
            self == .connecting || self == .stopping
        }
    }

    let devices: [Device]
    @Binding var selectedDeviceID: String?
    let threadID: UUID?
    let activeDeviceName: String?
    let phase: Phase
    let close: () -> Void
    let refresh: () -> Void
    let openSettings: () -> Void
    let requestConsent: (String, UUID) -> Void
    let confirmConsent: (String, UUID) -> Void
    let cancelConsent: () -> Void
    let stop: () -> Void

    private var selectedDevice: Device? {
        devices.first { $0.id == selectedDeviceID }
    }

    private var canRequestConsent: Bool {
        phase.allowsSelection && selectedDevice != nil && threadID != nil
    }

    private var canConfirmConsent: Bool {
        guard case let .consent(device, owner) = phase else { return false }
        return owner == threadID && devices.contains(device)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("iPad", systemImage: "ipad").font(.headline)
                Spacer()
                Button("關閉", systemImage: "xmark", action: close)
                    .labelStyle(.iconOnly).buttonStyle(.plain)
                    .help("關閉面板，不會停止設備")
            }

            if phase.allowsSelection {
                if devices.isEmpty {
                    Text("未找到已準備好的 iPad").foregroundStyle(.secondary)
                } else {
                    Picker("設備", selection: $selectedDeviceID) {
                        Text("選擇 iPad").tag(String?.none)
                        ForEach(devices) { device in
                            Text(device.name).tag(Optional(device.id))
                        }
                    }
                }
                if case let .failed(message) = phase {
                    Text(message).font(.callout).foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if threadID == nil {
                    Text("請先選擇討論串").font(.callout).foregroundStyle(.secondary)
                }
                HStack {
                    Button("重新尋找", action: refresh)
                    Button("設備設定", action: openSettings)
                    Spacer()
                }.controlSize(.small)
                Button("連線並授權", action: beginConsent)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canRequestConsent)
            } else {
                if case let .consent(device, _) = phase {
                    Text(device.name).font(.subheadline.bold())
                    Text("允許自動建置並安裝必要的連線元件，以及目前討論串的 AI 選擇 App、擷取畫面及觸控，直到停止或斷線。雲端模型會接收截圖，觸控可能修改 iPad 內容。")
                        .font(.callout).fixedSize(horizontal: false, vertical: true)
                    if !canConfirmConsent {
                        Text("討論串或設備已變更，請返回重新選擇。")
                            .font(.callout).foregroundStyle(.red)
                    }
                    HStack {
                        Button("返回", action: cancelConsent)
                        Spacer()
                        Button("同意並連線", action: confirm)
                            .buttonStyle(.borderedProminent)
                            .disabled(!canConfirmConsent)
                    }
                } else {
                    if let activeDeviceName {
                        Text(activeDeviceName).font(.subheadline.bold())
                    }
                    HStack(spacing: 8) {
                        if phase.isBusy {
                            ProgressView().controlSize(.small)
                        }
                        Text(statusText)
                            .foregroundStyle(phase == .stopUnconfirmed ? Color.red : Color.primary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Button(stopButtonTitle, role: .destructive, action: stop)
                        .disabled(phase == .stopping)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onExitCommand(perform: close)
        .accessibilityIdentifier("ipad-chat-connection-preview")
    }

    private var statusText: String {
        switch phase {
        case .connecting: return "正在連線…"
        case .authorizedHere: return "目前討論串可使用"
        case .ownedElsewhere: return "另一個討論串正在使用；目前討論串未獲授權。"
        case .stopping: return "正在停止並確認設備狀態…"
        case .stopUnconfirmed: return "停止尚未確認，請檢查 iPad。"
        default: return ""
        }
    }

    private var stopButtonTitle: String {
        switch phase {
        case .ownedElsewhere: return "停止其他討論串的連線"
        case .stopUnconfirmed: return "再次停止設備"
        default: return "立即停止"
        }
    }

    private func beginConsent() {
        guard canRequestConsent, let selectedDevice, let threadID else { return }
        requestConsent(selectedDevice.id, threadID)
    }

    private func confirm() {
        guard canConfirmConsent, case let .consent(device, owner) = phase else { return }
        confirmConsent(device.id, owner)
    }
}
