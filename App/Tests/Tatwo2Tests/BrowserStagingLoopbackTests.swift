import Foundation
import XCTest
@testable import Tatwo2

final class BrowserStagingLoopbackTests: XCTestCase {
    private let staging = [
        "TATWO_STAGING_ALLOW_BROWSER_LOOPBACK": "1",
        "TATWO_STAGING_SCRATCH_HOME": "/fixture/staging-home"
    ]
    private let bundle = "ai.tatwo.tatwo2.c2"

    private func decision(
        _ text: String, environment: [String: String], bundleIdentifier: String?
    ) throws -> EmbeddedBrowserNavigationDecision {
        EmbeddedBrowserNavigationPolicy.decision(
            for: try XCTUnwrap(URL(string: text)),
            environment: environment, bundleIdentifier: bundleIdentifier)
    }

    func testBrowserLoopbackRequiresAllStagingGates() throws {
        let url = "http://127.0.0.1:8765/"
        var environments: [[String: String]] = [[:]]
        for key in staging.keys {
            var missing = staging
            missing.removeValue(forKey: key)
            environments.append(missing)
        }
        for value in ["", "0", "true", "01", "1 ", " 1"] {
            var invalid = staging
            invalid["TATWO_STAGING_ALLOW_BROWSER_LOOPBACK"] = value
            environments.append(invalid)
        }
        for value in ["", " \n\t"] {
            var invalid = staging
            invalid["TATWO_STAGING_SCRATCH_HOME"] = value
            environments.append(invalid)
        }
        for environment in environments {
            XCTAssertEqual(try decision(url, environment: environment, bundleIdentifier: bundle),
                           .block(.nonPublicIPAddress))
        }
        for identity: String? in [nil, "", "ai.tatwo.tatwo2", "ai.tatwo.tatwo2.",
                                 "ai.tatwo.tatwo20.stage", "org.example.stage"] {
            XCTAssertEqual(try decision(url, environment: staging, bundleIdentifier: identity),
                           .block(.nonPublicIPAddress))
        }
    }

    func testBrowserStagingAllowsOnlyExactEndpoint() throws {
        for scheme in ["http", "https"] {
            let text = "\(scheme)://127.0.0.1:8765/drag.html?test=1#target"
            XCTAssertEqual(try decision(text, environment: staging, bundleIdentifier: bundle), .allow)
        }
        let denied = [
            "http://127.0.0.1:8766/", "http://127.0.0.1/", "https://127.0.0.1/",
            "http://127.0.0.2:8765/", "http://localhost:8765/",
            "http://a.localhost:8765/", "http://test.local:8765/",
            "http://[::1]:8765/", "http://[::ffff:127.0.0.1]:8765/",
            "http://10.0.0.1/", "http://172.16.0.1:8765/", "http://" + [192, 168, 1, 1].map(String.init).joined(separator: ".") + ":8765/",
            "http://user:pw@127.0.0.1:8765/", "http://@127.0.0.1:8765/",
            "http://127.1:8765/", "http://2130706433:8765/",
            "http://0x7f000001:8765/", "http://127.0.0.1.:8765/",
            "http://%31%32%37.0.0.1:8765/", "ftp://127.0.0.1:8765/"
        ]
        for text in denied {
            let url = try XCTUnwrap(URL(string: text))
            XCTAssertFalse(StagingBrowserLoopbackPolicy.allows(
                url, environment: staging, bundleIdentifier: bundle), text)
            XCTAssertNotEqual(try decision(text, environment: staging, bundleIdentifier: bundle),
                              .allow, text)
        }
    }

    func testBrowserStagingConfiguredPortAndInvalidSettingsFailClosed() throws {
        var environment = staging
        environment["TATWO_STAGING_BROWSER_LOOPBACK_PORT"] = "9001"
        XCTAssertEqual(try decision("http://127.0.0.1:9001/", environment: environment,
                                    bundleIdentifier: bundle), .allow)
        XCTAssertEqual(try decision("http://127.0.0.1:8765/", environment: environment,
                                    bundleIdentifier: bundle), .block(.nonPublicIPAddress))
        for text in ["", "0", "-1", "+8765", "65536", "8765 ", " 8765", "8x",
                     "８７６５", "999999999999999999999999999"] {
            environment["TATWO_STAGING_BROWSER_LOOPBACK_PORT"] = text
            XCTAssertNil(StagingBrowserLoopbackPolicy.enabledPort(
                environment: environment, bundleIdentifier: bundle), text)
            XCTAssertEqual(try decision("http://127.0.0.1:8765/", environment: environment,
                                        bundleIdentifier: bundle), .block(.nonPublicIPAddress))
        }
        for port in ["1", "65535"] {
            environment["TATWO_STAGING_BROWSER_LOOPBACK_PORT"] = port
            XCTAssertEqual(try decision("http://127.0.0.1:\(port)/", environment: environment,
                                        bundleIdentifier: bundle), .allow)
        }
    }

    func testBrowserRedirectTargetsAreReevaluatedWithoutSourceGrant() throws {
        // Policy-level redirect simulation, not a WKWebView/CEF network test.
        XCTAssertEqual(try decision("http://127.0.0.1:8765/redirect",
                                    environment: staging, bundleIdentifier: bundle), .allow)
        for target in ["http://127.0.0.2:8765/", "http://127.0.0.1:8766/",
                       "http://localhost:8765/", "http://10.0.0.1/",
                       "http://172.16.0.1/", "http://" + [192, 168, 1, 1].map(String.init).joined(separator: ".") + "/",
                       "http://[::1]:8765/", "http://[::ffff:127.0.0.1]:8765/"] {
            XCTAssertNotEqual(try decision(target, environment: staging, bundleIdentifier: bundle),
                              .allow, target)
        }
        XCTAssertEqual(try decision("https://example.com/", environment: staging,
                                    bundleIdentifier: bundle), .allow)
    }
}
