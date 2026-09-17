import SwiftUI

/// No eager model/service creation until the read-only first-run check has finished.
struct OSOnboardingGate: View {
    let finished: () -> Void
    @State private var required = false
    @State private var checking = true
    @State private var error = ""

    var body: some View {
        Group {
            if checking { ProgressView("檢查本機入口…") }
            else if required { OSOnboardingView(finished: finished) }
            else {
                VStack(spacing: 16) {
                    Text("入口需要檢查").font(.title)
                    Text(error).textSelection(.enabled)
                    HStack {
                        Button("重試") { check() }
                        // The OS must stay usable even when the entrance needs attention.
                        Button("先使用 App") { finished() }
                    }
                }.padding(32)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task { check() }
    }

    private func check() {
        checking = true
        Task {
            let result = await Task.detached { () -> Result<Bool, Error> in
                Result {
                    let entry = TatwoEntry()
                    // A broken entrance link (e.g. the primary's external volume is unmounted)
                    // is not a new device: never start onboarding over it.
                    if entry.status == .brokenSymbolicLink {
                        throw OSUpstreamBinding.failure("入口連結斷開：\(entry.root.path)。外接卷可能未掛載；掛載後按重試，或先使用 App。")
                    }
                    if OSOnboarding.needsOnboarding(entry: entry) { return true }
                    try OSOnboarding.repairMissingDirectories(entry: entry)
                    return false
                }
            }.value
            checking = false
            switch result {
            case .success(true): required = true
            case .success(false): finished()
            case .failure(let issue): error = issue.localizedDescription
            }
        }
    }
}

struct OSOnboardingView: View {
    let finished: () -> Void
    private let entry = TatwoEntry()
    private let home = FileManager.default.homeDirectoryForCurrentUser
    private let steps = ["歡迎", "環境偵測", "命名與角色", "工作環境", "引擎掃描", "產生預覽", "偏好", "邊界", "完成"]
    @State private var step = 0
    @State private var draft = OSOnboarding.defaultDraft(environment: ProcessInfo.processInfo.environment)
    @State private var hardware: OnboardingDiscovery.Hardware?
    @State private var preview: OSOnboarding.Preview?
    @State private var externalPath = ""
    @State private var error = ""
    @State private var busy = false
    @State private var discovering = true
    @State private var approved = false
    @State private var installed = false
    @ObservedObject private var gbrain = GBrainService.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text("TATWO OS").font(.headline)
                Spacer()
                Text("\(step + 1) / 9").foregroundStyle(.secondary)
            }
            ProgressView(value: Double(step + 1), total: 9)
            Text(steps[step]).font(.largeTitle.bold())
            ScrollView {
                VStack(alignment: .leading, spacing: 16) { page }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
            }
            if !error.isEmpty { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            if busy { ProgressView("處理中…") }
            if discovering { ProgressView("讀取本機環境與引擎版本…") }
            HStack {
                if step == 0 && !installed {
                    Button("稍後再說") { finished() }
                        .disabled(busy)
                        .help("先使用 App；下次開啟時會再提示接入")
                }
                Button("上一步") { step -= 1; approved = false }
                    .disabled(step == 0 || busy || installed)
                Spacer()
                if installed {
                    Button("進入 TATWO OS") { finished() }.buttonStyle(.borderedProminent)
                } else if step == 8 {
                    Button("確認寫入並接入") { install() }
                        .disabled(busy || !approved || preview == nil)
                        .buttonStyle(.borderedProminent)
                } else {
                    Button("下一步") { step += 1; approved = false }
                        .disabled(busy || discovering || (step == 2 && draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(40)
        .frame(minWidth: 540, minHeight: 580)
        .frame(maxWidth: 900)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            let home = home, environment = ProcessInfo.processInfo.environment
            let result = await Task.detached {
                (OnboardingDiscovery.hardware(home: home),
                 OnboardingDiscovery.engines(home: home, environment: environment))
            }.value
            hardware = result.0
            draft.hardwareModel = result.0.model
            draft.engines = result.1
            discovering = false
        }
        .task(id: step) {
            if step == 5 || step == 8 { await makePreview() }
        }
    }

    @ViewBuilder private var page: some View {
        switch step {
        case 0:
            Text("讓這台 Mac 加入同一套架構。所有變更都會先預覽，最後按「確認寫入並接入」才會寫入。")
            Text("將建立入口：\(entry.root.path)\n包含本機 device.json、gbrain、rooms、staging、archive、note。主設備使用 App 內建公開 v4 憲法；副設備等待簽章派發。")
            Text("可選擇納管 ~/.claude/CLAUDE.md、~/.codex/AGENTS.md；原檔先備份，可在設定 › OS 移除。引擎未安裝時不建立規則檔。")
            Text("App 執行期資料仍在系統的 Application Support；不搬動既有引擎資料、金鑰或資料庫。")
        case 1:
            LabeledContent("硬體型號", value: hardware?.model ?? "—")
            LabeledContent("記憶體", value: hardware?.memory ?? "—")
            LabeledContent("家目錄磁碟可用", value: hardware?.disk ?? "—")
            Text("直接讀取本機資料；讀不到的值顯示「—」，不推測配置。").foregroundStyle(.secondary)
        case 2:
            TextField("本機名稱", text: $draft.name)
            Picker("設備角色", selection: $draft.role) {
                Text("主設備").tag(DeviceRole.primary)
                Text("副設備").tag(DeviceRole.secondary)
            }.pickerStyle(.segmented).disabled(draft.hasPairedPrimary)
            Text(draft.primary.map { "已配對主設備：\($0.name)。不透過接入流程移交主權。" } ??
                 "第一台預設主設備。要加入既有系統請選副設備，接入後到「設備」完成配對。")
            Text(draft.role == .secondary ? "預設：不發版、不推公開倉、不手改憲法副本。" : "主設備保存規則正本與共用 GBrain。")
        case 3:
            Text("固定入口：\(entry.root.path)").font(.callout.monospaced())
            Picker("實體位置", selection: $externalPath) {
                Text("本機家目錄").tag("")
                ForEach(hardware?.externalVolumes ?? [], id: \.path) { volume in
                    Text(volume.lastPathComponent).tag(volume.appendingPathComponent("AI/TATWO OS").path)
                }
            }.disabled(entry.exists)
            Text(externalPath.isEmpty ? "所有 OS 資料集中於入口。" :
                 "實體資料：\(externalPath)\n在固定入口建立符號連結；不搬動或覆寫卷上的既有入口。")
            Text("工作房：rooms/　暫存：staging/　封存：archive/")
        case 4:
            if draft.engines.isEmpty { Text("尚未偵測到外部 Claude Code、Codex 或 Grok CLI。可稍後安裝並納管。") }
            ForEach($draft.engines) { $engine in
                VStack(alignment: .leading) {
                    Toggle("\(engine.id) · \(engine.version)", isOn: $engine.selected)
                        .disabled(engine.target == nil)
                    Text(engine.executable).font(.caption.monospaced()).textSelection(.enabled)
                    if engine.target == nil { Text("尚無已確認的外部全域規則路徑，只列出版本，不建檔。").font(.caption) }
                }
            }
        case 5:
            Text("W79 轉譯器預覽；這一步不寫入。偏好與邊界變更後，完成頁會再產生最後版本。")
            previewText
        case 6:
            Picker("能耗", selection: $draft.energy) {
                ForEach(["節能", "平衡", "效能"], id: \.self) { Text($0).tag($0) }
            }
            Picker("更新通道", selection: $draft.updateChannel) {
                Text("公開穩定版").tag("stable")
                Text("私人候選版").tag("beta")
            }
            Toggle("允許被遠端派工（仍須完成配對與授權）", isOn: $draft.allowsRemoteWork)
            Text("偏好記錄於本機身份；不授予超出既有配對與憲法的權限。").font(.caption)
        case 7:
            Text(draft.role == .secondary ? "副設備固定邊界：不發版、不推公開倉、不手改憲法副本、不推整合分支。" : "依憲法執行；發版、公開推送仍需使用者授權。")
            Text("其他限制（每行一項，只能加嚴）")
            TextEditor(text: $draft.extraBoundaries).frame(minHeight: 100)
        default:
            Text("其他設備會看到：\(draft.name) · \(draft.role == .primary ? "主設備" : "副設備") · \(draft.hardwareModel)")
            Text("遠端派工：\(draft.allowsRemoteWork ? "允許（須配對授權）" : "不允許")\n邊界：\(draft.boundaries.joined(separator: "、"))")
            if installed {
                Text(draft.role == .secondary ? "\(OSOnboarding.waiting)。請至設備頁配對並對齊；不建立本機 GBrain 資料庫。" : "入口已建立。GBrain：\(gbrain.status)")
                if draft.role == .primary && !gbrain.healthy {
                    Text("GBrain 尚未就緒不等於接入成功；可重試，詳情見設定 › 文件 › GBrain。")
                    Button("重試 GBrain") { gbrain.start() }
                }
            } else {
                previewText
                Toggle("我已確認最後預覽與寫入位置，允許先備份再建立管理區塊", isOn: $approved)
            }
        }
    }

    @ViewBuilder private var previewText: some View {
        if let preview { Text(preview.text).font(.caption.monospaced()).textSelection(.enabled) }
        else { Text("無可用預覽；請修正錯誤後回到這一步。") }
    }

    private func makePreview() async {
        approved = false
        busy = true
        defer { busy = false }
        draft.physicalRoot = externalPath.isEmpty ? nil : URL(fileURLWithPath: externalPath)
        let draft = draft, entry = entry
        let result = await Task.detached { Result { try OSOnboarding.preview(draft: draft, entry: entry) } }.value
        switch result {
        case .success(let value): preview = value; error = ""
        case .failure(let issue): preview = nil; error = issue.localizedDescription
        }
    }

    private func install() {
        guard let preview else { return }
        busy = true
        Task {
            let result = await Task.detached { Result { try OSOnboarding.install(preview) } }.value
            busy = false
            switch result {
            case .success:
                installed = true
                gbrain.start()
            case .failure(let issue):
                error = issue.localizedDescription
                approved = false
            }
        }
    }
}

struct ManagedRulesRemovalView: View {
    @State private var confirming = false
    @State private var message = ""
    @State private var busy = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button("移除 OS 管理區塊", role: .destructive) { confirming = true }.disabled(busy)
            Text("比對安裝前備份與目前檔案雜湊；有手改時停止，不覆蓋使用者內容。")
                .font(.caption).foregroundStyle(.secondary)
            if !message.isEmpty { Text(message).font(.caption).textSelection(.enabled) }
        }
        .confirmationDialog("移除各家引擎的 OS 管理區塊？入口、身份與 GBrain 不會刪除。", isPresented: $confirming) {
            Button("比對備份並移除", role: .destructive) {
                busy = true
                Task {
                    let result = await Task.detached { Result { try ManagedRulesRemoval.remove(entry: TatwoEntry()) } }.value
                    busy = false
                    switch result {
                    case .success: message = "已還原；各家檔案雜湊與安裝前一致。"
                    case .failure(let error): message = "未完成：" + error.localizedDescription
                    }
                }
            }
        }
    }
}
