import Foundation
import XCTest
@testable import Tatwo2

final class ComputerUseChatEntryTests: XCTestCase {
    private let caller = UUID()
    private func validate(_ method: String, _ values: [String: Any] = [:]) throws {
        var values = values
        values["callerThreadID"] = caller.uuidString
        try ChatPageModel.validateComputerToolParameters(method, params: values, caller: caller)
    }
    private func action(_ name: String, _ fields: [String: Any]) throws {
        var values = fields
        values["sessionID"] = UUID().uuidString
        values["observationID"] = UUID().uuidString
        values["action"] = name
        try validate("computer_action", values)
    }
    func testArbitraryTargetsAndListWithoutConsent() throws {
        try validate("computer_list_apps")
        try validate("computer_start", ["bundleIdentifier": "org.example.AnyApp"])
        try validate("computer_start", ["bundleIdentifier": "com.apple.Terminal"])
        XCTAssertThrowsError(try validate("computer_start"))
        for id in ["ai.tatwo.tatwo2.dev", "com.apple.Passwords", "com.bitwarden.desktop"] {
            XCTAssertThrowsError(try validate("computer_start", ["bundleIdentifier": id]))
        }
        for field in ["fileName", "documentURL", "workspace", "applicationPath", "scope", "consent"] {
            XCTAssertThrowsError(try validate("computer_start", ["bundleIdentifier": "org.example.App", field: "invalid"]))
        }
        XCTAssertThrowsError(try validate("computer_list_apps", ["sessionID": UUID().uuidString]))
    }
    func testEveryActionShape() throws {
        for name in ["click", "double_click", "right_click"] {
            try action(name, ["element": 0])
            try action(name, ["x": 12.5, "y": 100])
        }
        try action("scroll", ["element": 0, "dx": 0, "dy": 200])
        try action("scroll", ["x": 10, "y": 20, "dx": -100, "dy": 0])
        try action("drag", ["element": 0, "toElement": 4])
        try action("drag", ["x": 0, "y": 0, "toX": 100, "toY": 100])
        try action("type_text", ["text": "繁中🙂\n第二行"])
        try action("press_key", ["keys": "cmd+shift+s"])
        try action("set_value", ["element": 0, "text": ""])
        for name in ComputerUseNative.axActions {
            try action("perform_ax_action", ["element": 0, "name": name])
        }
        try action("focus_window", ["windowIndex": 1])
    }
    func testInvalidAndLegacyShapesFailBeforeNativeWork() {
        for (name, fields): (String, [String: Any]) in [
            ("click", ["element": 0, "x": 1, "y": 2]), ("click", ["element": true]),
            ("scroll", ["element": 0, "dx": 0, "dy": 0]), ("scroll", ["x": 1, "y": 2, "deltaY": 100]),
            ("drag", ["element": 0]), ("drag", ["element": 0, "toElement": 1, "toX": 1, "toY": 2]),
            ("type_text", ["value": "old"]), ("type_text", ["text": ""]),
            ("type_text", ["text": "\u{1b}"]), ("type_text", ["text": String(repeating: "字", count: 4097)]),
            ("press_key", ["keys": "ctrl+cmd+q"]), ("press_key", ["keys": "cmd+option+escape"]),
            ("set_value", ["element": 0]), ("perform_ax_action", ["element": 0, "name": "AXDelete"]),
            ("focus_window", ["windowIndex": -1]), ("document_menu", ["value": "new"]),
            ("file_panel", ["value": "confirm_file"])
        ] { XCTAssertThrowsError(try action(name, fields), name) }
    }
    func testCallerSessionAndObservationRemainRequired() throws {
        for method in ["computer_list_apps", "computer_start", "computer_observe", "computer_action", "computer_stop"] {
            for raw: Any in ["", true, UUID().uuidString, NSNull()] {
                XCTAssertThrowsError(try ChatPageModel.validateComputerToolParameters(method,
                    params: ["callerThreadID": raw], caller: caller)) {
                    XCTAssertEqual(($0 as? ComputerUseFailure)?.code, "computer_invalid_caller")
                }
            }
        }
        try validate("computer_stop")
        try validate("computer_observe", ["sessionID": UUID().uuidString])
        XCTAssertThrowsError(try validate("computer_observe", ["sessionID": "bad"]))
        XCTAssertThrowsError(try validate("computer_action", ["sessionID": UUID().uuidString,
            "observationID": "bad", "action": "click", "element": 0]))
        XCTAssertThrowsError(try validate("computer_action", ["sessionID": "bad",
            "observationID": UUID().uuidString, "action": "click", "element": 0]))
    }
}
