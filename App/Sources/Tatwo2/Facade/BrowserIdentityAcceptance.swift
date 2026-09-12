import Foundation

/// Pure engine selection and isolated profile-root checks. Never starts CEF,
/// opens a website, or accesses the host's browser profile.
enum BrowserIdentityAcceptance {
    private final class FixtureFileManager: FileManager, @unchecked Sendable {
        let support: URL
        init(support: URL) { self.support = support; super.init() }
        override func urls(for directory: FileManager.SearchPathDirectory,
                           in domainMask: FileManager.SearchPathDomainMask) -> [URL] {
            directory == .applicationSupportDirectory ? [support] : []
        }
    }

    @MainActor static func run() throws -> Bool {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["TATWO2_ISSUE_TEST_ROOT"],
              env["TATWO2_LIVE_ROOT"] == path + "/live",
              FileManager.default.fileExists(atPath: path + "/fixture-only") else { return false }
        var passed = 0, failed = 0
        func check(_ name: String, _ value: Bool) {
            if value { passed += 1 } else { failed += 1 }
            print("BROWSERIDENTITYTEST \(value ? "PASS" : "FAIL") \(name)")
        }
        func selected(_ id: String?, _ configured: String?, compiled: Bool = true) -> EmbeddedBrowserEngine {
            EmbeddedBrowserEnginePolicy.selectedEngine(
                bundleIdentifier: id, configuredEngine: configured, cefCompiled: compiled)
        }
        check("OS2 production selects explicitly configured Chromium",
              selected("ai.tatwo.tatwo2", "chromium-cef") == .chromiumCEF)
        check("OS2 missing CEF reports unavailable rather than silently switching engines",
              selected("ai.tatwo.tatwo2", "chromium-cef", compiled: false) == .chromiumUnavailable)
        check("legacy production remains compatible",
              selected("com.tatwo.ultrawork", "chromium-cef") == .chromiumCEF)
        check("staging remains compatible",
              selected("com.tatwo.ultrawork.staging.tatwo2", "chromium-cef") == .chromiumCEF)
        check("explicit legacy selection is retained",
              selected("ai.tatwo.tatwo2", "webkit-legacy") == .webKitLegacy)
        check("unconfigured builds do not silently activate a new engine",
              selected("ai.tatwo.tatwo2", nil) == .webKitLegacy)
        check("lookalike bundle cannot opt into production Chromium",
              selected("ai.tatwo.tatwo2.untrusted", "chromium-cef") == .webKitLegacy)
        check("unknown bundle cannot opt into production Chromium",
              selected(nil, "chromium-cef") == .webKitLegacy)
        check("renamed OS2 display name resolves the packaged helper",
              EmbeddedBrowserEnginePolicy.helperAppName(
                bundleIdentifier: "ai.tatwo.tatwo2", bundleName: "TATWO OS") == "tatwo2 Helper.app")
        check("legacy helper naming remains compatible",
              EmbeddedBrowserEnginePolicy.helperAppName(
                bundleIdentifier: "com.tatwo.ultrawork", bundleName: "Tatwo Ultrawork") == "Tatwo Ultrawork Helper.app")
        check("staging helper naming remains compatible",
              EmbeddedBrowserEnginePolicy.helperAppName(
                bundleIdentifier: "com.tatwo.ultrawork.staging.test", bundleName: "Staging Fixture") == "Staging Fixture Helper.app")
        let support = URL(fileURLWithPath: path).appendingPathComponent("support")
        let os2Root = TatwoCEFProfileLocationResolver.productionRootCacheURL(
            applicationSupportURL: support, bundleIdentifier: "ai.tatwo.tatwo2")
        check("OS2 root resolves beneath its own support directory",
              os2Root?.path == support.appendingPathComponent("tatwo2/chromium/cef-root").path)
        let legacyRoot = TatwoCEFProfileLocationResolver.productionRootCacheURL(applicationSupportURL: support)
        check("legacy root is preserved and not shared with OS2",
              legacyRoot != nil && legacyRoot != os2Root && legacyRoot?.path.contains("/Tatwo Ultrawork/") == true)
        check("OS2 expected log directory is created",
              FileManager.default.fileExists(atPath: support.appendingPathComponent("tatwo2/chromium/cef-logs").path))
        let rejectedSupport = URL(fileURLWithPath: path).appendingPathComponent("untrusted-support")
        check("unknown product root is refused without filesystem writes",
              TatwoCEFProfileLocationResolver.productionRootCacheURL(
                applicationSupportURL: rejectedSupport, bundleIdentifier: "ai.tatwo.tatwo2.untrusted") == nil
              && !FileManager.default.fileExists(atPath: rejectedSupport.path))
        let unsafeSupport = URL(fileURLWithPath: path).appendingPathComponent("unsafe-support")
        let outside = URL(fileURLWithPath: path).appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: unsafeSupport, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: unsafeSupport.appendingPathComponent("tatwo2"), withDestinationURL: outside)
        check("OS2 root refuses a symlink to another profile directory",
              TatwoCEFProfileLocationResolver.productionRootCacheURL(
                applicationSupportURL: unsafeSupport, bundleIdentifier: "ai.tatwo.tatwo2") == nil)
        check("rejected profile does not create artifacts in symlink target",
              (try FileManager.default.contentsOfDirectory(atPath: outside.path)).isEmpty)
        // Root selection never migrates/deletes WebKit cookies or legacy data.
        let marker = legacyRoot!.appendingPathComponent("fixture-existing-profile")
        try Data("preserve".utf8).write(to: marker)
        _ = TatwoCEFProfileLocationResolver.productionRootCacheURL(
            applicationSupportURL: support, bundleIdentifier: "ai.tatwo.tatwo2")
        check("activating OS2 does not overwrite an existing legacy profile",
              try String(contentsOf: marker, encoding: .utf8) == "preserve")
        let bundleRoot = URL(fileURLWithPath: path).appendingPathComponent("browser-fixture.app")
        let contents = bundleRoot.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let plist: [String: Any] = [
            "CFBundleIdentifier": "ai.tatwo.tatwo2", "CFBundleName": "TATWO OS",
            "CFBundlePackageType": "APPL", "CFBundleExecutable": "tatwo2",
            "TatwoBrowserEngine": "chromium-cef",
        ]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        let helperContents = contents.appendingPathComponent("Frameworks/tatwo2 Helper.app/Contents")
        try FileManager.default.createDirectory(at: helperContents.appendingPathComponent("MacOS"),
                                                withIntermediateDirectories: true)
        let helperPlist = ["CFBundleIdentifier": "ai.tatwo.tatwo2.helper.fixture",
                           "CFBundleExecutable": "tatwo2 Helper", "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: helperPlist, format: .xml, options: 0)
            .write(to: helperContents.appendingPathComponent("Info.plist"))
        let helperExecutable = helperContents.appendingPathComponent("MacOS/tatwo2 Helper")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: helperExecutable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helperExecutable.path)
        // Construct the complete artifact before asking Bundle to inspect it.
        // Foundation may cache the layout of a previously incomplete bundle.
        let bundle = Bundle(url: bundleRoot)!
        check("actual Bundle metadata selects the intended engine",
              selected(bundle.bundleIdentifier, bundle.object(forInfoDictionaryKey: "TatwoBrowserEngine") as? String) == .chromiumCEF)
        check("production bundle root resolver accepts OS2 with isolated filesystem",
              TatwoCEFProfileLocationResolver.rootCacheURL(
                bundle: bundle, fileManager: FixtureFileManager(support: support)) == os2Root)
        check("helper executable follows packaged CFBundleExecutable, not SwiftPM name",
              EmbeddedBrowserEnginePolicy.helperExecutableURL(in: bundle)?
                .standardizedFileURL.resolvingSymlinksInPath().path
                == helperExecutable.standardizedFileURL.resolvingSymlinksInPath().path)
        let missingRoot = URL(fileURLWithPath: path).appendingPathComponent("missing-helper.app")
        try FileManager.default.createDirectory(at: missingRoot.appendingPathComponent("Contents"),
                                                withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: missingRoot.appendingPathComponent("Contents/Info.plist"))
        check("missing helper is reported unavailable instead of inventing a path",
              EmbeddedBrowserEnginePolicy.helperExecutableURL(in: Bundle(url: missingRoot)!) == nil)
        if let suppliedBundle = env["TATWO2_BROWSER_BUNDLE_ROOT"] {
            guard let installed = Bundle(path: suppliedBundle) else {
                throw NSError(domain: "BrowserIdentityAcceptance.invalidBundle", code: 1)
            }
            check("supplied App metadata is the OS2 production product",
                  installed.bundleIdentifier == "ai.tatwo.tatwo2"
                  && installed.object(forInfoDictionaryKey: "TatwoBrowserEngine") as? String == "chromium-cef")
            check("candidate helper resolver matches supplied App artifact",
                  EmbeddedBrowserEnginePolicy.helperExecutableURL(in: installed) != nil)
        }
        if env["TATWO2_BROWSER_RUNTIME_BUNDLE_TEST"] == "1" {
            check("running isolated bundle has the real OS2 identity",
                  Bundle.main.bundleIdentifier == "ai.tatwo.tatwo2")
            check("current engine uses bundled identity and actual compiled CEF availability",
                  EmbeddedBrowserEnginePolicy.current == .chromiumCEF)
        }
        print("BROWSERIDENTITYTEST RESULT passed=\(passed) failed=\(failed) skipped=0")
        return failed == 0
    }
}
