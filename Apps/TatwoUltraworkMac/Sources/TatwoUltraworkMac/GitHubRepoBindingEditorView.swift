import SwiftUI
import TatwoUltraworkCore

/// Edits the project's GitHub repo bindings inline in the info card: several
/// URLs, each tagged with the login account it belongs to
/// (2026-09-02 使用者：可輸入多個網址並標註登入帳號).
struct GitHubRepoBindingEditorView: View {

    private struct Row: Identifiable, Equatable {
        let id = UUID()
        var url: String
        var accountLabel: String
        var visibility: TatwoGitHubRepoBinding.Visibility
        var original: TatwoGitHubRepoBinding?
    }

    private let onSave: ([TatwoGitHubRepoBinding]) -> Void
    private let onCancel: () -> Void
    @State private var rows: [Row]

    init(
        bindings: [TatwoGitHubRepoBinding],
        onSave: @escaping ([TatwoGitHubRepoBinding]) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.onSave = onSave
        self.onCancel = onCancel
        let existing = bindings.map {
            Row(url: $0.url, accountLabel: $0.accountLabel, visibility: $0.visibility, original: $0)
        }
        _rows = State(initialValue: existing.isEmpty ? [Row(url: "", accountLabel: "", visibility: .unknown, original: nil)] : existing)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("一個專案可以綁多個倉庫；每一列標註用哪個登入帳號。")
                .font(.caption2)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                    ForEach($rows) { $row in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 8) {
                                TextField("https://github.com/account/repo.git", text: $row.url)
                                    .textFieldStyle(.roundedBorder)
                                Button {
                                    rows.removeAll { $0.id == row.id }
                                    if rows.isEmpty {
                                        rows = [Row(url: "", accountLabel: "", visibility: .unknown, original: nil)]
                                    }
                                } label: {
                                    Image(systemName: "minus.circle")
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                                .help("移除這個倉庫")
                            }
                            TextField("登入帳號（例如 tatwo214）", text: $row.accountLabel)
                                .textFieldStyle(.roundedBorder)
                            Picker("可見性", selection: $row.visibility) {
                                Text("公開").tag(TatwoGitHubRepoBinding.Visibility.pub)
                                Text("私有").tag(TatwoGitHubRepoBinding.Visibility.priv)
                                Text("未知").tag(TatwoGitHubRepoBinding.Visibility.unknown)
                            }
                            .labelsHidden()
                            .pickerStyle(.segmented)
                        }
                        .padding(8)
                        .background(
                            Color.primary.opacity(0.04),
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
            }

            Button {
                rows.append(Row(url: "", accountLabel: "", visibility: .unknown, original: nil))
            } label: {
                Label("新增倉庫", systemImage: "plus")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)

            if let problem {
                Text(problem)
                    .font(.caption2)
                    .foregroundStyle(Color.orange)
            }

            HStack {
                Spacer()
                Button("取消", role: .cancel) { onCancel() }
                    .controlSize(.small)
                Button("儲存") { save() }
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.small)
                    .disabled(problem != nil)
            }
        }
    }

    private var normalizedRows: [(url: String, account: String, row: Row)] {
        rows.compactMap { row in
            let url = row.url.trimmingCharacters(in: .whitespacesAndNewlines)
            let account = row.accountLabel.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !url.isEmpty || !account.isEmpty else { return nil }  // blank row is ignored
            return (url, account, row)
        }
    }

    /// nil when the form can be saved (all-blank form saves an empty list,
    /// which unbinds every repo).
    private var problem: String? {
        var seen = Set<String>()
        for entry in normalizedRows {
            if entry.url.isEmpty { return "每個倉庫都要有網址" }
            if entry.account.isEmpty { return "請標註 \(entry.url) 用的登入帳號" }
            if !entry.url.hasPrefix("https://") && !entry.url.hasPrefix("git@") {
                return "網址要以 https:// 或 git@ 開頭：\(entry.url)"
            }
            if !seen.insert(entry.url.lowercased()).inserted { return "同一個網址不要重複：\(entry.url)" }
        }
        return nil
    }

    private func save() {
        guard problem == nil else { return }
        let bindings = normalizedRows.map { entry -> TatwoGitHubRepoBinding in
            let keepsPreviousCheck = entry.row.original?.url == entry.url
            return TatwoGitHubRepoBinding(
                url: entry.url,
                accountLabel: entry.account,
                visibility: entry.row.visibility,
                hasUpdate: keepsPreviousCheck ? entry.row.original?.hasUpdate ?? false : false,
                lastCheckedISO: keepsPreviousCheck ? entry.row.original?.lastCheckedISO : nil)
        }
        onSave(bindings)
    }
}
