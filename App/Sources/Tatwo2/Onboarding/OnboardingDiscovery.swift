import Foundation

enum OnboardingDiscovery {
    struct Hardware {
        let model: String
        let memory: String
        let disk: String
        let externalVolumes: [URL]
    }
    static func hardware(home: URL) -> Hardware {
        let model = (try? DeviceIdentityStore.hardwareModel()) ?? "—"
        let bytes = ProcessInfo.processInfo.physicalMemory
        let disk = (try? FileManager.default.attributesOfFileSystem(forPath: home.path)[.systemFreeSize]) as? NSNumber
        let keys: Set<URLResourceKey> = [.volumeIsInternalKey, .volumeIsReadOnlyKey]
        let volumes = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: Array(keys), options: [.skipHiddenVolumes]) ?? []
        return Hardware(model: model,
                        memory: bytes == 0 ? "—" : ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory),
                        disk: disk.map { ByteCountFormatter.string(fromByteCount: $0.int64Value, countStyle: .file) } ?? "—",
                        externalVolumes: volumes.filter {
                            guard let values = try? $0.resourceValues(forKeys: keys) else { return false }
                            return values.volumeIsInternal == false && values.volumeIsReadOnly == false
                        })
    }

    /// Search external installations only; never resolve to the App's bundled Helpers.
    static func engines(home: URL, environment: [String: String]) -> [OSOnboarding.Engine] {
        let paths = (environment["PATH"] ?? "").components(separatedBy: ":") +
            [home.appendingPathComponent(".local/bin").path, "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
        return RuleTranslators.all.compactMap { translator in
            guard let executable = paths.filter({ $0.hasPrefix("/") }).map({
                URL(fileURLWithPath: $0).appendingPathComponent(translator.engine)
            }).first(where: {
                FileManager.default.isExecutableFile(atPath: $0.path) &&
                !$0.resolvingSymlinksInPath().path.contains(".app/Contents/")
            }) else { return nil }
            let target = translator.externalFile.map {
                UpstreamBindingTarget(id: translator.engine + "-cli", label: translator.engine,
                                      path: home.appendingPathComponent($0).path)
            }
            return .init(id: translator.engine, executable: executable.path,
                         version: version(executable, home: home, environment: environment),
                         target: target, selected: target != nil)
        }
    }

    private static func version(_ executable: URL, home: URL, environment: [String: String]) -> String {
        let process = Process(), pipe = Pipe(), done = DispatchSemaphore(value: 0)
        process.executableURL = executable
        process.arguments = ["--version"]
        process.environment = ["HOME": home.path, "PATH": environment["PATH"] ?? "/usr/bin:/bin"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { _ in done.signal() }
        do {
            try process.run()
            if done.wait(timeout: .now() + 4) == .timedOut {
                process.terminate()
                // A version probe is never allowed to keep onboarding waiting.
                if done.wait(timeout: .now() + 1) == .timedOut { kill(process.processIdentifier, SIGKILL) }
                return "—"
            }
            guard process.terminationStatus == 0 else { return "—" }
            let bytes = try pipe.fileHandleForReading.read(upToCount: 4096) ?? Data()
            let value = String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? "—" : String(value.prefix(200))
        } catch { return "—" }
    }
}
