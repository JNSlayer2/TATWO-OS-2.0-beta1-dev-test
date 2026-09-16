import Foundation

/// SwiftPM's generated Bundle.module accessor traps if its build-time path and
/// executable-adjacent bundle are absent. A packaged macOS app stores the bundle
/// in Contents/Resources instead, so resolve it without invoking that accessor.
enum ProviderIconResources {
    static func url(for fileName: String, in bundle: Bundle = .main) -> URL? {
        TatwoResources.url(forResource: fileName, withExtension: "svg", in: bundle)
    }

    static func url(for fileName: String, roots: [URL]) -> URL? {
        TatwoResources.url(forResource: fileName, withExtension: "svg", roots: roots)
    }
}

enum TatwoResources {
    static var resourceURL: URL? {
        [Bundle.main.resourceURL, Bundle.main.bundleURL,
         Bundle.main.executableURL?.deletingLastPathComponent()]
            .compactMap { $0 }
            .map { $0.appendingPathComponent("TatwoUltrawork_Tatwo2.bundle", isDirectory: true) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    static func url(forResource fileName: String, withExtension ext: String?, in bundle: Bundle = .main) -> URL? {
        let roots = [
            bundle.resourceURL,
            bundle.bundleURL,
            bundle.executableURL?.deletingLastPathComponent()
        ].compactMap { $0 }
        return url(forResource: fileName, withExtension: ext, roots: roots)
    }

    static func url(forResource fileName: String, withExtension ext: String?, roots: [URL]) -> URL? {
        for root in roots {
            let packaged = root.appendingPathComponent("TatwoUltrawork_Tatwo2.bundle", isDirectory: true)
            for directory in [packaged, packaged.appendingPathComponent("ProviderIcons", isDirectory: true),
                              root, root.appendingPathComponent("ProviderIcons", isDirectory: true)] {
                let base = directory.appendingPathComponent(fileName)
                let candidate = ext.map { base.appendingPathExtension($0) } ?? base
                if FileManager.default.isReadableFile(atPath: candidate.path) {
                    return candidate
                }
            }
        }
        return nil
    }
}
