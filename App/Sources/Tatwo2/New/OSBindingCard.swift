// 2.0 新畫面（不是照搬）：設定頁「OS」— TATWO OS 當所有 AI 的最上游：入口在哪、哪些引擎接了、有沒有代差。
// 使用者 2026-09-05：以後接任何新模型只要接進 OS 就不用重設，並確保引擎之間沒有代差。
import SwiftUI

struct OSBindingCard: View {
    @ObservedObject var model: ChatPageModel
    @StateObject private var binding = OSBindingPreviewModel()

    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("OS")
                    .font(.title3.bold())
                Text("TATWO OS 是所有 AI 引擎的最上游：規矩在 os.md，每條對話開頭吃的那一頁在 os-upstream.md。接進來的引擎都讀同一份，就不會有代差。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            OSUpstreamUpdateView(update: .shared)

            HStack(spacing: 10) {
                Image(systemName: "externaldrive")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("入口").font(.caption).foregroundStyle(.secondary)
                    Text(model.osRootPath).font(.callout.monospaced()).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                Button("預覽差異") { binding.load(environment: model.osBindingEnvironment) }
                    .disabled(binding.busy)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                Button("重新檢查") {
                    model.refreshUpstreamBindings()
                    OSUpstreamUpdateModel.shared.reload(notify: true)
                }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }

            if let preview = binding.preview {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        if let error = preview.error { Text(error).foregroundStyle(.red) }
                        if preview.seed { Text("入口尚無 os-upstream.md：確認後種入內建一頁規則與 os.md v3，原憲法保留為 os.1.0.md。") }
                        ForEach(preview.items) { item in
                            VStack(alignment: .leading, spacing: 3) {
                                Text("\(item.id) · \(item.state.rawValue)").font(.caption.bold())
                                Text(item.path).font(.caption.monospaced())
                                Text("current: \(item.currentBlockHash ?? "—")\nexpected: \(item.expectedHash)").font(.caption2.monospaced())
                                if let error = item.error { Text(error).foregroundStyle(.red) }
                                if !item.diff.isEmpty { Text(item.diff).font(.caption.monospaced()).textSelection(.enabled) }
                            }
                            Divider()
                        }
                    }
                }
                .frame(maxHeight: 260)
                Button("寫入修復") {
                    binding.confirm(environment: model.osBindingEnvironment) { model.refreshUpstreamBindings() }
                }
                .disabled(binding.busy || preview.error != nil || preview.paths.isEmpty || !model.isLive)
            }
            if !binding.report.isEmpty {
                ScrollView { Text(binding.report).font(.caption.monospaced()).textSelection(.enabled) }
                    .frame(maxHeight: 130)
            }

            VStack(alignment: .leading, spacing: 6) {
                let counts = Self.counts(displayedBindings)
                Text("已接 \(counts.bound)・有代差 \(counts.stale)・還沒接 \(counts.unbound)・讀不到 \(counts.unreachable)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(displayedBindings) { item in
                    HStack(spacing: 10) {
                        Circle()
                            .fill(Self.color(item.state))
                            .frame(width: 8, height: 8)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.target.label).font(.subheadline)
                            Text(item.detail).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(item.target.path)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: 260, alignment: .trailing)
                    }
                    .padding(.vertical, 4)
                    Divider().opacity(0.4)
                }
                if displayedBindings.isEmpty {
                    Text("還沒檢查。").font(.caption).foregroundStyle(.tertiary)
                }
            }

            Text("綠＝已接且一致；黃＝一頁規則改過還沒重新對齊（先預覽，再確認寫入）；灰＝還沒接；紅＝那台或那個資料夾現在讀不到。")
                .font(.footnote)
                .foregroundStyle(.tertiary)
        }
        .padding(22)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .onAppear {
            model.refreshUpstreamBindings()
            let env = model.osBindingEnvironment
            if env["TATWO_ULTRAWORK_EXPORT_WINDOW_SNAPSHOT"] != nil,
               env["TATWO2_BIND_PREVIEW"] == "1" { binding.load(environment: env) }
        }
    }

    private var displayedBindings: [UpstreamBindingStatus] {
        guard let preview = binding.preview else { return model.upstreamBindings }
        return preview.items.map { item in
            .init(target: item.target,
                  state: item.state == .unreadable ? .unreachable : item.state == .bound ? .bound : item.state == .stale ? .stale : .unbound,
                  detail: item.error ?? item.state.rawValue)
        }
    }

    private static func color(_ state: UpstreamBindingStatus.State) -> Color {
        switch state {
        case .bound: .green
        case .stale: .yellow
        case .unbound: Color.secondary.opacity(0.4)
        case .unreachable: .red
        }
    }

    private static func counts(_ list: [UpstreamBindingStatus]) -> (bound: Int, stale: Int, unbound: Int, unreachable: Int) {
        (list.filter { $0.state == .bound }.count, list.filter { $0.state == .stale }.count,
         list.filter { $0.state == .unbound }.count, list.filter { $0.state == .unreachable }.count)
    }
}
