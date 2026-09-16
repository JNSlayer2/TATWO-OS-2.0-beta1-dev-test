import Foundation

/// Packaged apps use Contents/Resources; SwiftPM executables use an adjacent bundle.
/// Never fall back to a build-machine path or trap when a resource is missing.
enum TatwoResources {
    static func url(forResource name: String, withExtension ext: String?, subdirectory: String? = nil) -> URL? {
        let roots = [Bundle.main.resourceURL, Bundle.main.bundleURL,
                     Bundle.main.executableURL?.deletingLastPathComponent()]
        return url(forResource: name, withExtension: ext, subdirectory: subdirectory, roots: roots.compactMap { $0 })
            ?? Bundle.main.url(forResource: name, withExtension: ext, subdirectory: subdirectory)
    }

    static func url(forResource name: String, withExtension ext: String?, subdirectory: String? = nil, roots: [URL]) -> URL? {
        for root in roots {
            if let bundle = Bundle(url: root.appendingPathComponent("TatwoUltrawork_Tatwo2.bundle")),
               let url = bundle.url(forResource: name, withExtension: ext, subdirectory: subdirectory) {
                return url
            }
            let directory = subdirectory.map { root.appendingPathComponent($0) } ?? root
            let base = directory.appendingPathComponent(name)
            let candidate = ext.map { base.appendingPathExtension($0) } ?? base
            if FileManager.default.isReadableFile(atPath: candidate.path) { return candidate }
        }
        return nil
    }
}
