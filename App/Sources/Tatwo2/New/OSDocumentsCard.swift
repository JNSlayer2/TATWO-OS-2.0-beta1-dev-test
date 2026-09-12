// 2.0 新畫面（不是照搬）：設定頁「文件」— os.md／skillet.md／os-upstream.md（你改）、todo.md／issue.md（工程用）在 App 裡可看可改。
// 使用者 2026-09-05 點頭。改動先備份；「請 AI 整理」要你按「套用」才寫檔。
import SwiftUI

struct OSDocumentsCard: View {
    @ObservedObject var model: ChatPageModel
    @State private var selectedID: String?
    @State private var draft = ""
    @State private var loadedFor: String?

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            list
                .frame(width: 210)
            editor
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(22)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            if selectedID == nil { selectedID = model.osDocuments.first?.id }
            syncDraft()
        }
        .onChange(of: selectedID) { _ in syncDraft() }
        .onChange(of: model.osDocumentText) { _ in
            if let id = selectedID, loadedFor != id, let text = model.osDocumentText[id] { draft = text; loadedFor = id }
        }
    }

    // MARK: 左列

    private var list: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("文件")
                .font(.title3.bold())
            section("給你看、給你改的", model.osDocuments.filter { $0.audience == .user })
            section("工程用（你可以看、可以留話）", model.osDocuments.filter { $0.audience == .engineering })
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
        if let id = selectedID, let doc = model.osDocuments.first(where: { $0.id == id }) {
            let dirty = draft != (model.osDocumentText[id] ?? "")
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Text(doc.title).font(.headline)
                    Text(doc.path).font(.caption).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    if dirty {
                        Button("放棄修改") { draft = model.osDocumentText[id] ?? "" }
                            .buttonStyle(.bordered).controlSize(.small)
                        Button("存檔") { model.saveOSDocument(id: id, text: draft) }
                            .buttonStyle(.borderedProminent).controlSize(.small)
                            .disabled(!doc.isEditable)
                    }
                }
                if !doc.isEditable {
                    Text("這份只能看，不能改。").font(.footnote).foregroundStyle(.secondary)
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
                                    model.saveOSDocument(id: id, text: pending)
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
            Text("左邊選一份文件。")
                .foregroundStyle(.secondary)
        }
    }

    private func syncDraft() {
        guard let id = selectedID else { return }
        if let text = model.osDocumentText[id] { draft = text; loadedFor = id } else { model.loadOSDocument(id: id); loadedFor = nil }
    }
}
