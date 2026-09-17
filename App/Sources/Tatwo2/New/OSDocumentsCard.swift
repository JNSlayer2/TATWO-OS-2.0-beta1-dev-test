// 2.0 新畫面（不是照搬）：設定頁「文件」— os.md／skillet.md／os-upstream.md（你改）、todo.md／issue.md（工程用）在 App 裡可看可改。
// 使用者 2026-09-05 點頭。改動先備份；「請 AI 整理」要你按「套用」才寫檔。
import SwiftUI

struct OSDocumentsCard: View {
    @ObservedObject var model: ChatPageModel
    @State private var selectedID: String?
    @State private var draft = ""
    @State private var loadedFor: String?
    @State private var baseText = ""
    @State private var proposals: [DeviceInbox.Proposal] = []
    @State private var dispatchStatus = ""
    @State private var acceptedProposalID: String?

    var body: some View {
        Group {
            if !TatwoEntry().exists {
                VStack(alignment: .leading, spacing: 8) {
                    Text("找不到入口 \(TatwoEntry().root.path)")
                        .textSelection(.enabled)
                    if TatwoEntry().status == .brokenSymbolicLink {
                        Text("入口連結已斷開").foregroundStyle(.secondary)
                    }
                    Button("重新讀取") { syncDraft() }
                }
            } else {
                HStack(alignment: .top, spacing: 16) {
                    list
                        .frame(width: 210)
                    editor
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            if selectedID == nil { selectedID = model.osDocuments.first?.id }
            syncDraft()
        }
        .onChange(of: selectedID) { _ in syncDraft() }
        .onChange(of: model.osDocumentText) { _ in
            if let id = selectedID, loadedFor != id, let text = model.osDocumentText[id] {
                draft = text; baseText = text; loadedFor = id
            }
        }
        .task {
            while !Task.isCancelled {
                proposals = DeviceInbox.shared.proposals()
                if let id = selectedID, let sent = proposals.last(where: { $0.document == id }),
                   sent.status == "sent", sent.id != acceptedProposalID,
                   baseText == sent.base || baseText == sent.text {
                    baseText = sent.text; acceptedProposalID = sent.id
                    // Refresh the accepted baseline, never replace a draft that the
                    // user continued editing while the request was in flight.
                    model.loadOSDocument(id: id)
                }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    // MARK: 左列

    private var list: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("文件")
                .font(.title3.bold())
            section("給你看、給你改的", model.osDocuments.filter { $0.audience == .user })
            section("工程用（你可以看、可以留話）", model.osDocuments.filter { $0.audience == .engineering })
            Text("記憶").font(.caption).foregroundStyle(.secondary)
            Button("GBrain") { selectedID = "gbrain" }
                .buttonStyle(.plain)
        }
    }

    private func section(_ title: String, _ docs: [OSDocument]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(docs) { doc in
                Button {
                    selectedID = doc.id
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(doc.title)
                            .font(.subheadline.weight(selectedID == doc.id ? .semibold : .regular))
                        Text(doc.whatItIsFor)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8).padding(.vertical, 6)
                    .background(selectedID == doc.id ? Color.accentColor.opacity(0.12) : Color.clear,
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: 右邊：編輯

    @ViewBuilder
    private var editor: some View {
        if selectedID == "gbrain" {
            GBrainSettingsView()
        } else if let id = selectedID, let doc = model.osDocuments.first(where: { $0.id == id }) {
            if let error = model.osDocumentReadErrors[id] {
                VStack(alignment: .leading, spacing: 8) {
                    Text(error).textSelection(.enabled)
                    Text(doc.path).font(.caption).textSelection(.enabled)
                    Button("重新讀取") { syncDraft() }
                }
            } else if model.osDocumentText[id] != nil {
            let dirty = draft != (model.osDocumentText[id] ?? "")
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Text(doc.title).font(.headline)
                    Spacer()
                    if dirty {
                        Button("放棄修改") { draft = model.osDocumentText[id] ?? "" }
                            .buttonStyle(.bordered).controlSize(.small)
                        Button("存檔") { saveDocument(id: id, text: draft) }
                            .buttonStyle(.borderedProminent).controlSize(.small)
                            .disabled(!doc.isEditable)
                    }
                }
                Text(doc.path).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(doc.path).textSelection(.enabled)
                if !doc.isEditable {
                    Text("這份只能看，不能改。").font(.footnote).foregroundStyle(.secondary)
                }
                if let status = model.osDocumentSaveStatus[id] {
                    Text(status).font(.footnote).textSelection(.enabled)
                } else if (id == "todo" || id == "issue") && !OSDocuments.isPrimary {
                    Text("副設備：未提交").font(.footnote).foregroundStyle(.secondary)
                }
                if !dispatchStatus.isEmpty { Text(dispatchStatus).font(.footnote).textSelection(.enabled) }
                if !OSDocuments.isPrimary, let proposal = proposals.last(where: { $0.document == id }) {
                    Text(proposal.status == "sent" ? "已送主設備並讀回同版" :
                         proposal.status == "conflict" ? "● 衝突：兩邊原件保留，請選三方差異" : "待送出的修改（原件未改）")
                        .font(.footnote).foregroundStyle(proposal.status == "conflict" ? Color.red : Color.secondary)
                    if proposal.status == "sent", let date = proposal.updated {
                        Text("最後同步：\(date.formatted())").font(.caption).foregroundStyle(.secondary)
                    }
                    if let error = proposal.error { Text(error).font(.caption).foregroundStyle(.orange) }
                    if proposal.status == "conflict" {
                        ScrollView(.horizontal) {
                            HStack(alignment: .top) {
                                conflictColumn("共同基準", proposal.base)
                                conflictColumn("本次修改", proposal.text)
                                conflictColumn("主設備目前", proposal.primaryText ?? "")
                                if let local = proposal.localText { conflictColumn("本機原件另有修改", local) }
                            }
                        }.frame(maxHeight: 220)
                        HStack {
                            Button("選本次修改") { resolve(proposal, useProposal: true) }
                            Button("選主設備版本") { resolve(proposal, useProposal: false) }
                        }
                    }
                }
                TextEditor(text: $draft)
                    .font(.system(size: 12.5, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 260, maxHeight: .infinity)
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.secondary.opacity(0.25), lineWidth: 1))
                    .disabled(!doc.isEditable)

                // 請 AI 整理
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        TextField("想怎麼整理，一句話（可留空）", text: Binding(
                            get: { model.osDocumentNote[id] ?? "" },
                            set: { model.osDocumentNote[id] = $0 }))
                            .textFieldStyle(.roundedBorder)
                        Button("請 AI 整理") { model.tidyOSDocument(id: id) }
                            .buttonStyle(.bordered).controlSize(.small)
                            .disabled(!doc.isEditable)
                    }
                    if let pending = model.osDocumentPending[id] {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("AI 整理好的版本（還沒寫進檔案）")
                                .font(.footnote.weight(.semibold))
                            ScrollView {
                                Text(pending)
                                    .font(.system(size: 12, design: .monospaced))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(maxHeight: 220)
                            HStack {
                                Spacer()
                                Button("不要") { model.osDocumentPending[id] = nil }
                                    .buttonStyle(.bordered).controlSize(.small)
                                Button("套用並存檔") {
                                    draft = pending
                                    saveDocument(id: id, text: pending)
                                    model.osDocumentPending[id] = nil
                                }
                                .buttonStyle(.borderedProminent).controlSize(.small)
                            }
                        }
                        .padding(10)
                        .background(Color.accentColor.opacity(0.07), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                }
                Text("每次存檔前會先備份一份到同目錄的 .tatwo2-backups/。os-upstream.md 存了，下一條新對話就生效。")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
            }
            } else {
                ProgressView("讀取文件")
            }
        } else {
            Text("左邊選一份文件。")
                .foregroundStyle(.secondary)
        }
    }

    private func syncDraft() {
        guard let id = selectedID else { return }
        guard id != "gbrain" else { return }
        loadedFor = nil
        draft = ""
        model.loadOSDocument(id: id)
        if let text = model.osDocumentText[id] { draft = text; baseText = text; loadedFor = id }
        dispatchStatus = ""
    }

    private func saveDocument(id: String, text: String) {
        if OSDocuments.isPrimary || id == "os-upstream" {
            model.saveOSDocument(id: id, text: text)
        } else {
            do {
                _ = try DeviceInbox.shared.enqueue(id: id, text: text, base: baseText)
                dispatchStatus = "已存成本機待送出的修改；連線後自動送主設備"
            } catch { dispatchStatus = error.localizedDescription }
            proposals = DeviceInbox.shared.proposals()
        }
    }
    private func conflictColumn(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading) {
            Text(title).font(.caption.bold())
            ScrollView { Text(text).font(.caption.monospaced()).textSelection(.enabled) }
        }.frame(width: 240)
    }
    private func resolve(_ proposal: DeviceInbox.Proposal, useProposal: Bool) {
        do {
            try DeviceInbox.shared.resolve(id: proposal.id, useProposal: useProposal)
            proposals = DeviceInbox.shared.proposals()
        } catch { dispatchStatus = error.localizedDescription }
    }
}

private struct GBrainSettingsView: View {
    @ObservedObject private var service = GBrainService.shared
    @State private var openAI = ""
    @State private var anthropic = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("GBrain").font(.headline)
            Text("OS 的共用記憶庫（在主設備）").foregroundStyle(.secondary)
            Label(service.status, systemImage: service.healthy ? "checkmark.circle.fill" : "exclamationmark.circle")
                .foregroundStyle(service.healthy ? Color.green : Color.orange)
            if let count = service.pageCount { Text("頁數：\(count)") }
            Text("最後寫入：\(service.lastWrite.isEmpty ? "尚無資料" : service.lastWrite)")
            Text(service.directory).font(.caption).textSelection(.enabled)
            Button("在 Finder 打開") { NSWorkspace.shared.open(URL(fileURLWithPath: service.directory)) }
            HStack {
                Button("重新查詢") { service.refresh() }
                Button("啟動") { service.start() }
                Button("停止") { service.stop() }
            }
            DisclosureGroup("API 金鑰") {
                VStack(alignment: .leading, spacing: 10) {
                    if !service.isPrimary {
                        Text("語意搜尋在主設備 \(service.primaryName) 執行，請在主設備設定").foregroundStyle(.secondary)
                    }
                    keyRow("OpenAI", provider: "openai", configured: service.openAIConfigured, text: $openAI)
                    keyRow("Anthropic（選用）", provider: "anthropic", configured: service.anthropicConfigured, text: $anthropic)
                    Toggle("語意搜尋", isOn: Binding(get: { service.semanticEnabled }, set: { service.setSemantic($0) }))
                        .disabled(!service.isPrimary || !service.openAIConfigured)
                        .disabled(service.mode == "legacy")
                    if service.mode == "legacy" {
                        Text("既有 Postgres 的搜尋沿用原服務，本單不變更設定").foregroundStyle(.secondary)
                    } else if !service.semanticEnabled { Text("目前只有關鍵字搜尋").foregroundStyle(.secondary) }
                }.disabled(!service.isPrimary)
            }
            if !service.message.isEmpty { Text(service.message).font(.caption) }
        }.onAppear { service.refresh(); service.start() }
    }
    private func keyRow(_ label: String, provider: String, configured: Bool, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
            if configured { Text("已設定").foregroundStyle(.secondary) }
            else { SecureField("API 金鑰", text: text) }
            HStack {
                Button("儲存到鑰匙圈") { service.saveKey(text.wrappedValue, provider: provider); text.wrappedValue = "" }
                    .disabled(text.wrappedValue.isEmpty || configured)
                Button("測試") { service.testKey(provider: provider) }.disabled(!configured)
                Button("移除") { service.removeKey(provider: provider) }.disabled(!configured)
            }
        }
    }
}
