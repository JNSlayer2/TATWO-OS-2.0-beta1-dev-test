import Foundation

/// Packaged apps use Contents/Resources; SwiftPM executables use an adjacent bundle.
/// Never fall back to a build-machine path or trap when a resource is missing.
enum TatwoResources {
    static func url(forResource name: String, withExtension ext: String?, subdirectory: String? = nil) -> URL? {
        let roots = [Bundle.main.resourceURL, Bundle.main.bundleURL,
                     Bundle.main.executableURL?.deletingLastPathComponent()]
        for root in roots.compactMap({ $0 }) {
            if let bundle = Bundle(url: root.appendingPathComponent("TatwoUltrawork_Tatwo2.bundle")),
               let url = bundle.url(forResource: name, withExtension: ext, subdirectory: subdirectory) {
                return url
            }
        }
        return Bundle.main.url(forResource: name, withExtension: ext, subdirectory: subdirectory)
    }
}
