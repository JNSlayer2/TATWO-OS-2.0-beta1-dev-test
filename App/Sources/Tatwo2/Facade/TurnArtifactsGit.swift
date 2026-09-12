import Foundation
import Darwin

enum TurnArtifactsGit {
    /// Existing gitSummary's reader, bounded by output and wall time; caller is a utility queue.
    static func run(_ args: [String], cwd: String) -> String? {
        precondition(!Thread.isMainThread)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 5)
        timer.setEventHandler {
            if process.isRunning, process.processIdentifier > 1 { kill(process.processIdentifier, SIGKILL) }
        }
        timer.resume()
        defer { timer.cancel(); try? pipe.fileHandleForReading.close() }
        var data = Data()
        while let chunk = try? pipe.fileHandleForReading.read(upToCount: min(65536, 262145 - data.count)), !chunk.isEmpty {
            data.append(chunk)
            if data.count > 262144 {
                if process.isRunning, process.processIdentifier > 1 { kill(process.processIdentifier, SIGKILL) }
                process.waitUntilExit()
                return nil
            }
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func paths(_ status: String) -> [String] {
        let fields = status.split(separator: "\0", omittingEmptySubsequences: true)
        var result: [String] = []
        var i = 0
        while i < fields.count && result.count <= TurnArtifacts.maxPaths {
            let field = fields[i]
            if field.count >= 4 {
                result.append(String(field.dropFirst(3)))
                if field.prefix(2).contains("R") || field.prefix(2).contains("C") { i += 1 }
            }
            i += 1
        }
        return result
    }
}
