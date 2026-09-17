import Foundation

/// W74: one logical entrance on every device; do not resolve away the mini's symlink.
struct TatwoEntry {
    enum Status: String {
        case available
        case missing
        case brokenSymbolicLink
        case notDirectory
    }

    let root: URL

    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        preference: String? = UserDefaults.standard.string(forKey: "tatwo2.osRoot"),
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        let path = [environment["TATWO_OS_ROOT"], environment["TATWO2_OS_ROOT"], preference]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        if let path {
            let expanded: String
            if path == "~" {
                expanded = homeDirectory.path
            } else if path.hasPrefix("~/") {
                expanded = homeDirectory.appendingPathComponent(String(path.dropFirst(2))).path
            } else {
                expanded = path
            }
            // Keep the caller's spelling: standardizedFileURL strips /private and would
            // disagree with realpath-based callers; symlinks (the mini entrance) stay intact.
            root = URL(fileURLWithPath: expanded, isDirectory: true)
        } else {
            root = homeDirectory.appendingPathComponent("AI/TATWO OS", isDirectory: true)
        }
    }

    var constitution: URL { root.appendingPathComponent("os.md") }
    var skillet: URL { root.appendingPathComponent("skillet.md") }
    var deviceJSON: URL { root.appendingPathComponent("device.json") }
    var gbrainDir: URL { root.appendingPathComponent("gbrain", isDirectory: true) }
    var noteDir: URL { root.appendingPathComponent("note", isDirectory: true) }
    var repoRoot: URL { root.appendingPathComponent("tatwo2", isDirectory: true) }
    var repoDocs: URL { repoRoot.appendingPathComponent("docs", isDirectory: true) }

    var exists: Bool { status == .available }

    var status: Status {
        let manager = FileManager.default
        var directory: ObjCBool = false
        if manager.fileExists(atPath: root.path, isDirectory: &directory) {
            return directory.boolValue ? .available : .notDirectory
        }
        // Also recognize a broken link in a parent component of the entrance.
        var candidate = root
        while candidate.path != "/" {
            if (try? manager.destinationOfSymbolicLink(atPath: candidate.path)) != nil,
               !manager.fileExists(atPath: candidate.path) {
                return .brokenSymbolicLink
            }
            candidate.deleteLastPathComponent()
        }
        return .missing
    }
}
