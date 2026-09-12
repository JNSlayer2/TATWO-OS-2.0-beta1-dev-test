import Foundation

struct PRPlanReview: Codable, Equatable, Sendable {
    let directory: URL
    let repository: String
    let account: String
    let snapshot: PullRequestService.Snapshot
    var submittedURL: URL?
    var attempted = false

    static let titles = ["標題", "改了什麼", "動到的檔", "怎麼驗的", "風險與回滾"]
    static func sections(_ reply: String) -> [TatwoPlanArtifactV1.Section]? {
        guard let sections = TatwoPlanArtifactV1.parseSections(fromReply: reply, fenceName: "tatwo-pr"),
              sections.map(\.title) == titles, sections.allSatisfy({ !$0.body.isEmpty }) else { return nil }
        return sections
    }
    struct FileDiff: Identifiable {
        var id: String { path }
        let path: String
        var lines: [String] = []
        var added = 0
        var removed = 0
        var preview: String { lines.prefix(400).joined(separator: "\n") + (lines.count > 400 ? "\n…" : "") }
    }
    static func files(_ diff: String) -> [FileDiff] {
        var files: [FileDiff] = []
        var index: Int?
        var inHunk = false
        for line in diff.components(separatedBy: "\n") {
            if line.hasPrefix("diff --git ") {
                let marker = line.range(of: " b/", options: .backwards)
                    ?? line.range(of: " \"b/", options: .backwards)
                let path = marker.map { String(line[$0.upperBound...]) } ?? String(line.dropFirst(11))
                index = files.firstIndex { $0.path == path }
                if index == nil { files.append(FileDiff(path: path)); index = files.count - 1 }
                inHunk = false
            }
            guard let index else { continue }
            files[index].lines.append(line)
            if line.hasPrefix("@@ ") { inHunk = true; continue }
            if inHunk && line.hasPrefix("+") { files[index].added += 1 }
            if inHunk && line.hasPrefix("-") { files[index].removed += 1 }
        }
        return files
    }
}
