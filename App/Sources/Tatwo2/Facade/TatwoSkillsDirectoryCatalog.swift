import Foundation

/// Read-only canonical skills catalog. Runtime projections and revision storage are separate.
struct TatwoSkillsDirectoryCatalog: Sendable {
    let rootURL: URL

    static func defaultRoot() -> URL {
        let environment = ProcessInfo.processInfo.environment
        if let path = environment["TATWO_SKILLS_ROOT"], !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Tatwo Ultrawork/skills", isDirectory: true)
    }

    func scanOutcome(allowExternalVolumes: Bool) -> TatwoSkillsScanOutcome {
        if !allowExternalVolumes && rootURL.resolvingSymlinksInPath().path.hasPrefix("/Volumes/") {
            return .init(value: nil, access: .notEnabled)
        }
        return scanOutcome(registeredPaths: [])
    }

    func scanOutcome(registeredPaths: Set<String>) -> TatwoSkillsScanOutcome {
        // Snapshot exports must never sweep private host skills.
        if ProcessInfo.processInfo.environment.keys.contains(where: { $0.hasPrefix("TATWO_ULTRAWORK_EXPORT_") }) {
            return .init(value: [])
        }
        do {
            let manager = FileManager.default
            let children = try manager.contentsOfDirectory(at: rootURL.resolvingSymlinksInPath(), includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            let registered = Set(registeredPaths.filter { $0.hasPrefix("/") }.map {
                URL(fileURLWithPath: $0).resolvingSymlinksInPath().path
            })
            var seen = Set<String>()
            var entries: [TatwoSkillsDirectoryEntryV1] = []
            for child in children.sorted(by: { $0.path < $1.path }) {
                let directory = child.resolvingSymlinksInPath()
                let manifest = directory.appendingPathComponent("SKILL.md")
                guard manager.fileExists(atPath: manifest.path), seen.insert(directory.path).inserted else { continue }
                let text = try String(contentsOf: manifest, encoding: .utf8)
                let metadata = Self.metadata(text)
                entries.append(.init(
                    id: child.lastPathComponent, name: metadata.name ?? child.lastPathComponent,
                    summary: metadata.summary, path: directory.path, hasManifest: true,
                    isRegistered: registered.contains(directory.path) || registered.contains(manifest.path)))
            }
            return .init(value: entries.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }, access: .enabled)
        } catch {
            let error = error as NSError
            let failure: ExternalVolumeFailure
            switch error.code {
            case NSFileReadNoSuchFileError, NSFileNoSuchFileError: failure = .volumeAbsent
            case NSFileReadNoPermissionError: failure = .permissionDenied
            default: failure = .ioError
            }
            return .init(value: nil, failure: failure)
        }
    }

    static func metadata(_ text: String) -> (name: String?, summary: String?) {
        let lines = text.components(separatedBy: .newlines)
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return (nil, nil) }
        var values: [String: String] = [:]
        var multilineKey: String?
        for line in lines.dropFirst() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "---" { break }
            if let key = multilineKey, line.hasPrefix(" ") || line.hasPrefix("\t") {
                values[key, default: ""] += (values[key, default: ""].isEmpty ? "" : " ") + trimmed
                continue
            }
            multilineKey = nil
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon])
            guard key == "name" || key == "description" else { continue }
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if [">", "|", ">-", "|-"].contains(value) { multilineKey = key; values[key] = "" }
            else { values[key] = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'")) }
        }
        return (values["name"].flatMap { $0.isEmpty ? nil : $0 }, values["description"])
    }
}
