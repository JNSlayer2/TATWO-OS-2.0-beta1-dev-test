import AppKit
import ApplicationServices
import XCTest
@testable import Tatwo2

final class ComputerUseNativeTests: XCTestCase {
    func testConsentTimeoutRequiresTimerAbortAndCurrentContext() {
        XCTAssertEqual(ComputerUseController.consentFailureCode(
            response: .abort, timedOut: true, contextIsCurrent: true),
            "computer_consent_timed_out")
        XCTAssertEqual(ComputerUseController.consentFailureCode(
            response: .abort, timedOut: false, contextIsCurrent: true),
            "computer_consent_cancelled")
        XCTAssertEqual(ComputerUseController.consentFailureCode(
            response: .alertSecondButtonReturn, timedOut: true, contextIsCurrent: true),
            "computer_consent_cancelled")
    }

    func testRevokedConsentNeverAuthorizesOrReportsOnlyTimeout() {
        let responses: [NSApplication.ModalResponse] = [.alertFirstButtonReturn, .alertSecondButtonReturn, .abort]
        for response in responses {
            for timedOut in [false, true] {
                XCTAssertEqual(ComputerUseController.consentFailureCode(
                    response: response, timedOut: timedOut, contextIsCurrent: false),
                    "computer_consent_cancelled")
            }
        }
    }

    func testConsentAcceptancePredicateRemainsUnchanged() {
        for timedOut in [false, true] {
            XCTAssertNil(ComputerUseController.consentFailureCode(
                response: .alertFirstButtonReturn, timedOut: timedOut, contextIsCurrent: true))
        }
        XCTAssertEqual(ComputerUseController.consentFailureCode(
            response: .alertSecondButtonReturn, timedOut: false, contextIsCurrent: true),
            "computer_consent_cancelled")
    }


    func testArbitraryTargetsAndDenyList() throws {
        for id in ["com.apple.TextEdit", "com.apple.calculator", "com.apple.Terminal", "org.example.Editor"] {
            XCTAssertEqual(try ComputerUseTarget.requested(id).bundleIdentifier, id)
        }
        for id in Array(ComputerUseTarget.deniedIdentifiers) + ["ai.tatwo.tatwo2", "ai.tatwo.tatwo2.dev", "com.apple.Passwords"] {
            XCTAssertThrowsError(try ComputerUseTarget.requested(id)) {
                XCTAssertEqual(($0 as? ComputerUseFailure)?.code, "computer_target_denied")
            }
        }
        XCTAssertThrowsError(try ComputerUseTarget.requested("org.example.Self", ownIdentifier: "org.example.Self"))
        for value: Any? in [nil, "", "../app", " id", true, NSNull(), String(repeating: "a", count: 256)] {
            XCTAssertThrowsError(try ComputerUseTarget.requested(value))
        }
        XCTAssertTrue(ComputerUseTarget.consentDetail.contains("付款、對外發送、刪除資料或更改帳號安全設定"))
        XCTAssertTrue(ComputerUseTarget.consentDetail.contains("最多 15 分鐘"))
    }

    func testGenericKeyParser() throws {
        for (name, code) in ComputerUseNative.keyCodes {
            XCTAssertEqual(try ComputerUseNative.parseKey(name).code, code)
            if !["q", "escape"].contains(name) {
                XCTAssertEqual(try ComputerUseNative.parseKey("cmd+shift+option+ctrl+fn+" + name).code, code, name)
            }
        }
    }

    func testKeyModifiersPunctuationAndDeniedChords() throws {
        let save = try ComputerUseNative.parseKey("cmd+shift+s")
        XCTAssertEqual(save.code, 1)
        XCTAssertEqual(save.flags, [.maskCommand, .maskShift])
        XCTAssertEqual(try ComputerUseNative.parseKey("CTRL+option+f5").flags, [.maskControl, .maskAlternate])
        XCTAssertEqual(try ComputerUseNative.parseKey("cmd++").code, 24)
        XCTAssertEqual(try ComputerUseNative.parseKey("?").flags, .maskShift)
        for key in ["ctrl+cmd+q", "cmd+ctrl+q", "cmd+option+escape", "option+shift+cmd+escape"] {
            XCTAssertThrowsError(try ComputerUseNative.parseKey(key)) {
                XCTAssertEqual(($0 as? ComputerUseFailure)?.code, "computer_key_denied")
            }
        }
        for key in ["", "cmd+", "cmd+cmd+s", "meta+s", "f13", "unknown", "cmd++s"] {
            XCTAssertThrowsError(try ComputerUseNative.parseKey(key), key)
        }
    }

    func testSecureValuesAreNeverReadAndInputIsDenied() throws {
        for (role, subrole) in [("AXSecureTextField", ""), ("AXTextField", kAXSecureTextFieldSubrole)] {
            var reads = 0
            let value = try ComputerUseNative.observedValue(role: role, subrole: subrole) {
                reads += 1
                throw ComputerUseFailure("must_not_read")
            }
            XCTAssertEqual(value, "•••")
            XCTAssertEqual(reads, 0)
            XCTAssertThrowsError(try ComputerUseNative.requireNonSecure(role: role, subrole: subrole)) {
                XCTAssertEqual(($0 as? ComputerUseFailure)?.code, "computer_secure_field_denied")
            }
        }
        XCTAssertNoThrow(try ComputerUseNative.requireNonSecure(role: "AXTextField", subrole: nil))
    }

    func testBoundedTreeFormattingAndPixelFrames() {
        let node = ComputerUseNative.Node(depth: 2, role: "AXButton", title: "儲存\n[next]", value: "hello",
            frame: CGRect(x: 110, y: 220, width: 30, height: 40), actions: ["AXPress"], focused: true, disabled: true)
        let tree = ComputerUseNative.render([node], frame: CGRect(x: 100, y: 200, width: 800, height: 600), width: 1600, height: 1200)
        XCTAssertTrue(tree.text.hasPrefix("    [0] AXButton"))
        XCTAssertTrue(tree.text.contains("frame=(20.0,40.0,60.0,80.0)"))
        XCTAssertTrue(tree.text.contains("actions=[AXPress] (focused) (disabled)"))
        XCTAssertEqual(tree.text.filter { $0 == "\n" }.count, 1)
        XCTAssertFalse(tree.truncated)
        let long = ComputerUseNative.Node(depth: 40, role: "AXTextField", title: String(repeating: "字", count: 500),
            value: String(repeating: "文", count: 500), frame: nil, actions: [], focused: false, disabled: false)
        let large = ComputerUseNative.render(Array(repeating: long, count: 800), frame: .zero, width: 0, height: 0)
        XCTAssertTrue(large.truncated)
        XCTAssertLessThanOrEqual(large.text.utf8.count, 80 * 1024)
        XCTAssertLessThanOrEqual(large.text.split(separator: "\n").count, 600)
        XCTAssertFalse(large.text.contains(String(repeating: "字", count: 301)))
    }

    func testExpiredAttributeDeadlineFailsBeforeAccessibilityLookup() {
        let node = AXUIElementCreateApplication(getpid())
        XCTAssertThrowsError(try ComputerUseNative.attribute(node, kAXRoleAttribute, deadline: 0)) {
            XCTAssertEqual(($0 as? ComputerUseFailure)?.code, "computer_observation_timeout")
        }
    }
}
