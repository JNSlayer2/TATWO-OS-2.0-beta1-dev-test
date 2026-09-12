import Foundation
import TatwoUltraworkCore

struct ChatRouteReceiptJournal {
    let rootURL: URL

    init(
        rootURL: URL = TatwoRuntimeLayout.applicationSupportRoot()
    ) {
        self.rootURL = rootURL.standardizedFileURL
    }

    var receiptURL: URL {
        rootURL
            .appendingPathComponent(
                "journals/chat-route-receipts",
                isDirectory: true)
            .appendingPathComponent(
                "claude-route-spawn.md",
                isDirectory: false)
            .standardizedFileURL
    }

    func append(
        header: String,
        entry: String,
        fileManager: FileManager = .default
    ) throws {
        let target = receiptURL
        guard target.path.hasPrefix(rootURL.path + "/") else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        try fileManager.createDirectory(
            at: target.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        if !fileManager.fileExists(atPath: target.path) {
            try header.write(
                to: target,
                atomically: true,
                encoding: .utf8)
        }
        let handle = try FileHandle(forWritingTo: target)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(entry.utf8))
    }
}
