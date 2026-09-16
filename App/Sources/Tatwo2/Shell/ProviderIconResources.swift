import Foundation

/// Shares the packaged-resource resolver; never invokes SwiftPM's trapping accessor.
enum ProviderIconResources {
    static func url(for fileName: String) -> URL? {
        TatwoResources.url(forResource: fileName, withExtension: "svg")
            ?? TatwoResources.url(forResource: fileName, withExtension: "svg", subdirectory: "ProviderIcons")
    }

    static func url(for fileName: String, roots: [URL]) -> URL? {
        TatwoResources.url(forResource: fileName, withExtension: "svg", roots: roots)
            ?? TatwoResources.url(forResource: fileName, withExtension: "svg", subdirectory: "ProviderIcons", roots: roots)
    }
}
