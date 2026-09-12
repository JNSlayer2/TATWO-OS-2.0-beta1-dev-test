import Foundation

/// Portable resource-bundle lookup for a signed `.app`.
///
/// SwiftPM's generated `Bundle.module` looks at `App.app/Name.bundle` (illegal
/// in a sealed bundle root) and then at the compile-time build path. That
/// second path does not exist on any other machine, so a copied App crashes.
/// These helpers only search locations that the installer actually stages.
public enum TatwoBundledResources {
    public static var core: Bundle {
        requiredBundle(named: "TatwoUltrawork_TatwoUltraworkCore")
    }

    public static var app: Bundle {
        requiredBundle(named: "TatwoUltrawork_TatwoUltraworkMac")
    }

    public static func requiredBundle(named name: String) -> Bundle {
        if let bundle = bundle(named: name) {
            return bundle
        }
        return Bundle.main
    }

    public static func bundle(named name: String) -> Bundle? {
        let fileName = name.hasSuffix(".bundle") ? name : "\(name).bundle"
        var seen = Set<String>()
        for url in candidateURLs(fileName: fileName) {
            let path = url.path
            guard !seen.contains(path) else { continue }
            seen.insert(path)
            if let bundle = Bundle(url: url) {
                return bundle
            }
        }
        return nil
    }

    private static func candidateURLs(fileName: String) -> [URL] {
        var urls: [URL] = []
        if let resourceURL = Bundle.main.resourceURL {
            urls.append(resourceURL.appendingPathComponent(fileName))
        }
        urls.append(
            Bundle.main.bundleURL
                .appendingPathComponent("Contents/Resources", isDirectory: true)
                .appendingPathComponent(fileName)
        )
        urls.append(Bundle.main.bundleURL.appendingPathComponent(fileName))

        if let executablePath = Bundle.main.executablePath {
            let exeDir = URL(fileURLWithPath: executablePath).deletingLastPathComponent()
            urls.append(exeDir.appendingPathComponent(fileName))
            urls.append(
                exeDir
                    .appendingPathComponent("../Resources", isDirectory: true)
                    .standardized
                    .appendingPathComponent(fileName)
            )
        }

        var cursor = URL(fileURLWithPath: CommandLine.arguments[0]).standardized
        for _ in 0..<8 {
            cursor = cursor.deletingLastPathComponent()
            if cursor.path == "/" { break }
            urls.append(cursor.appendingPathComponent(fileName))
        }
        return urls
    }
}
