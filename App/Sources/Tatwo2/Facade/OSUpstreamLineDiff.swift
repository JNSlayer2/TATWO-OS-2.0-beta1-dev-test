import Foundation

/// Line-based edit script, retaining empty lines and a final newline as separate entries.
enum OSUpstreamLineDiff {
    struct Line: Identifiable, Equatable {
        enum Kind: Equatable {
            case context, removed, added
            var prefix: String {
                switch self {
                case .context: return " "
                case .removed: return "−"
                case .added: return "+"
                }
            }
        }
        let id: Int
        let kind: Kind
        let runtimeLine: Int?
        let bundledLine: Int?
        let text: String
    }

    static func lines(runtime: String, bundled: String) -> [Line] {
        let old = runtime.components(separatedBy: "\n")
        let new = bundled.components(separatedBy: "\n")
        let changes = new.difference(from: old, by: { $0.utf8.elementsEqual($1.utf8) })
        var removed = Set<Int>(), added = Set<Int>()
        for change in changes {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): added.insert(offset)
            }
        }
        var rows: [Line] = []
        var i = 0, j = 0
        while i < old.count || j < new.count {
            if i < old.count, removed.contains(i) {
                rows.append(Line(id: rows.count, kind: .removed, runtimeLine: i + 1, bundledLine: nil, text: old[i]))
                i += 1
            } else if j < new.count, added.contains(j) {
                rows.append(Line(id: rows.count, kind: .added, runtimeLine: nil, bundledLine: j + 1, text: new[j]))
                j += 1
            } else {
                rows.append(Line(id: rows.count, kind: .context, runtimeLine: i + 1, bundledLine: j + 1, text: old[i]))
                i += 1
                j += 1
            }
        }
        return rows
    }
}
