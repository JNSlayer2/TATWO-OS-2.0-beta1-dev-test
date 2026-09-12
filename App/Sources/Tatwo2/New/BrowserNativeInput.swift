import AppKit

/// Browser-only input primitives. No global event posting, activation or GUI lookup.
enum BrowserNativeInput {
    enum Phase: Int { case down, move, up }

    struct ScreenshotGeometry {
        let id: UUID
        let fingerprint: String
        let pixels: NSSize

        func point(x: Double, y: Double, view: NSSize, observationID: UUID?, currentFingerprint: String) throws -> NSPoint {
            guard id == observationID, fingerprint == currentFingerprint else {
                throw BrowserAgentRequestError("browser_screenshot_coordinates_required")
            }
            return try BrowserNativeInput.screenshotPoint(x: x, y: y, pixels: pixels, view: view)
        }
    }

    /// Each send includes the caller's gate. Cleanup intentionally bypasses a
    /// revoked grant, but can only release the original receiver's held button.
    static func pointer(from: NSPoint, to: NSPoint, dragging: Bool,
                        send: (Phase, NSPoint) throws -> Void,
                        release: (NSPoint) -> Void,
                        pause: () -> Void = { Thread.sleep(forTimeInterval: 0.016) }) throws {
        var held = false
        var last = from
        defer { if held { release(last) } }
        // Arm before dispatch: a throwing sender might have partially delivered.
        held = true
        try send(.down, from)
        if dragging {
            for index in 1...12 {
                pause()
                let t = CGFloat(index) / 12
                last = NSPoint(x: from.x + (to.x - from.x) * t,
                               y: from.y + (to.y - from.y) * t)
                try send(.move, last)
            }
        }
        try send(.up, last)
        held = false
    }

    static func screenshotPoint(x: Double, y: Double, pixels: NSSize, view: NSSize) throws -> NSPoint {
        guard [x, y, Double(pixels.width), Double(pixels.height),
               Double(view.width), Double(view.height)].allSatisfy(\.isFinite),
              pixels.width > 0, pixels.height > 0, view.width > 0, view.height > 0,
              x >= 0, y >= 0, x < pixels.width, y < pixels.height else {
            throw BrowserAgentRequestError("browser_coordinate_out_of_bounds")
        }
        return NSPoint(x: CGFloat(x) * view.width / pixels.width, y: CGFloat(y) * view.height / pixels.height)
    }

    static func viewPoint(_ topLeft: NSPoint, bounds: NSRect, flipped: Bool) -> NSPoint {
        NSPoint(x: bounds.minX + topLeft.x,
                y: flipped ? bounds.minY + topLeft.y : bounds.maxY - topLeft.y)
    }

    static func requireSafeFocus(_ value: Any?) throws {
        guard let safe = value as? NSNumber,
              CFGetTypeID(safe) == CFBooleanGetTypeID(), safe.boolValue else {
            throw BrowserAgentRequestError("browser_password_or_uninspectable_focus_denied")
        }
    }

    struct Key {
        let code: UInt16
        let flags: NSEvent.ModifierFlags
        let characters: String
        let unmodified: String
        let windowsCode: Int32
    }

    // Same physical key names as external Computer Use, deliberately browser-local.
    static let codes: [String: UInt16] = [
        "a":0,"s":1,"d":2,"f":3,"h":4,"g":5,"z":6,"x":7,"c":8,"v":9,
        "b":11,"q":12,"w":13,"e":14,"r":15,"y":16,"t":17,
        "1":18,"2":19,"3":20,"4":21,"6":22,"5":23,"=":24,"9":25,"7":26,
        "-":27,"8":28,"0":29,"]":30,"o":31,"u":32,"[":33,"i":34,"p":35,
        "return":36,"l":37,"j":38,"'":39,"k":40,";":41,"\\":42,",":43,
        "/":44,"n":45,"m":46,".":47,"tab":48,"space":49,"`":50,
        "backspace":51,"delete":51,"escape":53,"enter":76,"forward_delete":117,
        "home":115,"end":119,"pageup":116,"pagedown":121,
        "left":123,"right":124,"down":125,"up":126,
        "f1":122,"f2":120,"f3":99,"f4":118,"f5":96,"f6":97,
        "f7":98,"f8":100,"f9":101,"f10":109,"f11":103,"f12":111
    ]

    static func parseKey(_ string: String) throws -> Key {
        var parts = string.lowercased().split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        if string == "+" || string.hasSuffix("++") {
            parts.removeLast()
            if parts.last == "" { parts.removeLast() }
            parts.append("+")
        }
        guard let last = parts.popLast(), !last.isEmpty else { throw BrowserAgentRequestError("browser_invalid_key") }
        let modifiers: [String: NSEvent.ModifierFlags] = [
            "cmd":.command,"shift":.shift,"option":.option,"ctrl":.control,"fn":.function]
        var flags: NSEvent.ModifierFlags = []
        for part in parts {
            guard let flag = modifiers[part], !flags.contains(flag) else { throw BrowserAgentRequestError("browser_invalid_key") }
            flags.insert(flag)
        }
        let shifted = ["!":"1","@":"2","#":"3","$":"4","%":"5","^":"6","&":"7","*":"8","(":"9",")":"0",
                       "_":"-","+":"=","{":"[","}":"]","|":"\\",":":";","\"":"'","<":",",">":".","?":"/","~":"`"]
        let base = shifted[last] ?? last
        if shifted[last] != nil { flags.insert(.shift) }
        guard let code = codes[base] else { throw BrowserAgentRequestError("browser_invalid_key") }
        guard !(base == "q" && flags.contains([.control, .command])),
              !(base == "escape" && flags.contains([.command, .option])) else {
            throw BrowserAgentRequestError("browser_key_denied")
        }
        // WebKit may resend unhandled command events to AppKit. Browser grants
        // do not authorize app/window/menu commands. Keep ordinary editing and
        // page zoom chords; do not expose quit/close/new-window shortcuts.
        if flags.contains(.command) {
            guard ["a", "c", "v", "x", "z", "y", "=", "-", "0"].contains(base),
                  flags.subtracting([.command, .shift]).isEmpty else {
                throw BrowserAgentRequestError("browser_key_denied")
            }
        }
        let special: [String: (UInt32, Int32)] = [
            "return":(13,13),"enter":(3,13),"tab":(9,9),"escape":(27,27),"space":(32,32),
            "backspace":(127,8),"delete":(127,8),"forward_delete":(0xF728,46),
            "up":(0xF700,38),"down":(0xF701,40),"left":(0xF702,37),"right":(0xF703,39),
            "home":(0xF729,36),"end":(0xF72B,35),"pageup":(0xF72C,33),"pagedown":(0xF72D,34)]
        let unmodified: String
        let windowsCode: Int32
        if let value = special[base] {
            unmodified = String(UnicodeScalar(value.0)!)
            windowsCode = value.1
        } else if base.hasPrefix("f"), let index = Int(base.dropFirst()), (1...12).contains(index) {
            unmodified = String(UnicodeScalar(UInt32(0xF703 + index))!)
            windowsCode = Int32(111 + index)
        } else {
            unmodified = base
            let punctuation: [String: Int32] = [";":186,"=":187,",":188,"-":189,".":190,"/":191,"`":192,
                                              "[":219,"\\":220,"]":221,"'":222]
            windowsCode = punctuation[base] ?? Int32(base.uppercased().utf16.first!)
        }
        let characters = flags.contains(.shift)
            ? (shifted.first { $0.value == base }?.key ?? unmodified.uppercased()) : unmodified
        return Key(code: code, flags: flags, characters: characters, unmodified: unmodified, windowsCode: windowsCode)
    }
}
