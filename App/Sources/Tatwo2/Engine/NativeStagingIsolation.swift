import Foundation
import Darwin

/// Normal staging uses real engines, but must not inherit the formal App's
/// credentials or plugin discovery roots. This is not a fixture/test mode.
enum NativeStagingIsolation {
    static func isEnabled(_ environment: [String: String]) -> Bool {
        guard let home = environment["TATWO_STAGING_SCRATCH_HOME"] else { return false }
        return !home.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// A marker is not permission to fall back to production when roots are
    /// missing. Validate before reaping processes or creating engine homes.
    static func validationError(_ environment: [String: String]) -> String? {
        guard isEnabled(environment) else { return nil }
        guard let path = environment["TATWO_STAGING_ROOT"], path.hasPrefix("/"),
              path != "/", URL(fileURLWithPath: path).pathComponents.count >= 3
        else { return "missing staging root" }
        let root = URL(fileURLWithPath: path, isDirectory: true)
        let keys = [
            "HOME", "CFFIXED_USER_HOME", "TATWO_STAGING_SCRATCH_HOME", "TATWO2_LIVE_ROOT",
            "TATWO2_ENGINES_ROOT", "CODEX_HOME", "TATWO2_CODEX_SOURCE_HOME",
            "CLAUDE_CONFIG_DIR", "CLAUDE_SECURESTORAGE_CONFIG_DIR",
            "TATWO2_OS_SOCKET", "TATWO2_BROWSER_SOCKET", "TATWO2_OS_ROOT",
            "TATWO2_DOCS_ROOT", "TATWO2_OS_UPSTREAM_PATH", "TATWO2_SKILLET_PATH",
        ]
        for key in keys {
            guard let value = environment[key], value.hasPrefix("/"),
                  URL(fileURLWithPath: value).standardizedFileURL.path != root.standardizedFileURL.path,
                  allowsRead(URL(fileURLWithPath: value), within: root)
            else { return "invalid staging path: \(key)" }
        }
        guard environment["HOME"] == environment["TATWO_STAGING_SCRATCH_HOME"],
              environment["CFFIXED_USER_HOME"] == environment["HOME"],
              environment["CODEX_HOME"] == environment["TATWO2_CODEX_SOURCE_HOME"],
              environment["CLAUDE_CONFIG_DIR"] == environment["CLAUDE_SECURESTORAGE_CONFIG_DIR"],
              environment["CODEX_HOME"] == environment["TATWO2_ENGINES_ROOT"]! + "/codex",
              environment["CLAUDE_CONFIG_DIR"] == environment["TATWO2_ENGINES_ROOT"]! + "/claude"
        else { return "inconsistent staging engine homes" }
        guard let osSocket = environment["TATWO2_OS_SOCKET"],
              let browserSocket = environment["TATWO2_BROWSER_SOCKET"],
              let resolvedOS = resolvedPathAllowingMissingLeaf(URL(fileURLWithPath: osSocket)),
              let resolvedBrowser = resolvedPathAllowingMissingLeaf(URL(fileURLWithPath: browserSocket)),
              resolvedOS != resolvedBrowser,
              osSocket.utf8.count < 104, browserSocket.utf8.count < 104
        else { return "invalid staging socket endpoints" }
        return nil
    }

    /// Keep the existing shared namespace in production. A staging engine must
    /// use its own config directory even if the parent supplied an empty value.
    static func sidecarClaudeNamespace(
        environment: [String: String], configDirectory: String
    ) -> String {
        isEnabled(environment) ? configDirectory : ""
    }

    static func isolateClaude(
        _ environment: [String: String], configDirectory: String
    ) -> [String: String] {
        var result = environment
        result["CLAUDE_CONFIG_DIR"] = configDirectory
        if isEnabled(environment) {
            result["CLAUDE_SECURESTORAGE_CONFIG_DIR"] = configDirectory
        }
        return result
    }

    /// Do not follow skill/config links out of the explicitly selected root.
    /// The staging launcher separately validates that these roots are new and
    /// candidate-owned before the App enters main().
    static func allowsRead(_ file: URL, within root: URL) -> Bool {
        // Do not normalize ".." across a symlink before checking containment.
        guard file.isFileURL, root.isFileURL,
              !file.pathComponents.contains(".."), !root.pathComponents.contains("..")
        else { return false }
        let rootPath = lexicalPath(root)
        let filePath = lexicalPath(file)
        guard filePath == rootPath || filePath.hasPrefix(rootPath + "/") else { return false }
        guard let resolvedRoot = resolvedPathAllowingMissingLeaf(root),
              let resolvedFile = resolvedPathAllowingMissingLeaf(file)
        else { return false }
        // Reject an aliased root too, rather than blessing a host directory.
        guard resolvedRoot == rootPath else { return false }
        return resolvedFile == rootPath || resolvedFile.hasPrefix(rootPath + "/")
    }

    /// URL standardization can shorten an existing /private/var path to /var
    /// but leave a nonexistent child unchanged. Keep physical-path comparison
    /// independent of that existence-dependent Foundation behavior.
    private static func lexicalPath(_ url: URL) -> String {
        "/" + url.pathComponents.filter { $0 != "/" && $0 != "." }.joined(separator: "/")
    }

    /// Foundation may return the original URL when the final component does
    /// not exist, leaving an existing parent symlink unresolved. Resolve the
    /// deepest existing ancestor instead; a dangling link, loop, inaccessible
    /// path, or non-directory parent fails closed rather than becoming "missing".
    private static func resolvedPathAllowingMissingLeaf(_ url: URL) -> String? {
        var ancestor = url
        var missing: [String] = []
        while true {
            var metadata = stat()
            let result = ancestor.path.withCString { lstat($0, &metadata) }
            if result == 0 {
                guard missing.isEmpty || (metadata.st_mode & S_IFMT) == S_IFDIR
                        || (metadata.st_mode & S_IFMT) == S_IFLNK,
                      let canonical = ancestor.path.withCString({ realpath($0, nil) })
                else { return nil }
                defer { free(canonical) }
                let resolved = String(cString: canonical)
                if !missing.isEmpty {
                    var target = stat()
                    guard lstat(canonical, &target) == 0,
                          (target.st_mode & S_IFMT) == S_IFDIR else { return nil }
                }
                let suffix = missing.reversed().filter { $0 != "." }.joined(separator: "/")
                return suffix.isEmpty ? resolved : (resolved == "/" ? "/" : resolved + "/") + suffix
            }
            guard errno == ENOENT, ancestor.path != "/" else { return nil }
            missing.append(ancestor.lastPathComponent)
            ancestor.deleteLastPathComponent()
        }
    }
}
