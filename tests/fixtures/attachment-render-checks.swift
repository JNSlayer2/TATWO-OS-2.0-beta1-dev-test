// Linked to the current production tile/strip source by the test runner.
@MainActor func runAttachmentRenderChecks() throws {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let root = URL(fileURLWithPath: CommandLine.arguments[1])
    var passed = 0, failed = 0
    func check(_ name: String, _ value: Bool) {
        if value { passed += 1 } else { failed += 1 }
        print("ATTACHMENTRENDERTEST \(value ? "PASS" : "FAIL") \(name)")
    }
    let input = root.appendingPathComponent("範例圖片.png")
    let image = NSImage(size: NSSize(width: 800, height: 500))
    image.lockFocus()
    NSColor.systemTeal.setFill()
    NSBezierPath(rect: NSRect(x: 0, y: 0, width: 800, height: 500)).fill()
    NSColor.systemYellow.setFill()
    NSBezierPath(ovalIn: NSRect(x: 245, y: 95, width: 310, height: 310)).fill()
    image.unlockFocus()
    let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
    try rep.representation(using: .png, properties: [:])!.write(to: input)
    var loaderChecksDone = false
    Task { @MainActor in
        let thumbnail = await ChatAttachmentImageLoader.shared.load(url: input, maxPixelSize: 160)
        check("loader bounds decoded dimensions", thumbnail != nil && max(thumbnail!.width, thumbnail!.height) <= 160)
        let missing = await ChatAttachmentImageLoader.shared.load(
            url: root.appendingPathComponent("missing.png"), maxPixelSize: 160)
        check("missing image returns empty state", missing == nil)
        let corrupt = root.appendingPathComponent("corrupt.png")
        try? Data("not an image".utf8).write(to: corrupt)
        let invalid = await ChatAttachmentImageLoader.shared.load(url: corrupt, maxPixelSize: 160)
        check("invalid image returns empty state", invalid == nil)
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await ChatAttachmentImageLoader.shared.load(url: input, maxPixelSize: 160)
        }
        let cancelledImage = await cancelled.value
        check("cancelled load does not publish pixels", cancelledImage == nil)
        loaderChecksDone = true
    }
    let deadline = Date().addingTimeInterval(8)
    while !loaderChecksDone && Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    }
    check("async loader completes", loaderChecksDone)
    let view = NSHostingView(rootView: ChatAttachmentStrip(attachments: [
        .init(path: input.path, name: nil),
        .init(path: root.appendingPathComponent("找不到的圖片.png").path, name: nil)
    ], maxWidth: 330).padding(20).frame(width: 370, height: 250, alignment: .topLeading)
        .background(Color.white).environment(\.colorScheme, .light))
    view.appearance = NSAppearance(named: .aqua)
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 370, height: 250),
                          styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = view
    window.orderBack(nil)
    view.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.5))
    view.layoutSubtreeIfNeeded()
    let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
    view.cacheDisplay(in: view.bounds, to: bitmap)
    try bitmap.representation(using: .png, properties: [:])!
        .write(to: root.appendingPathComponent("attachments.png"))
    func color(_ x: Int, _ y: Int) -> NSColor {
        bitmap.colorAt(x: x * bitmap.pixelsWide / 370, y: y * bitmap.pixelsHigh / 250)!
            .usingColorSpace(.deviceRGB)!
    }
    let thumbnail = color(40, 40)
    check("real async thumbnail appears", thumbnail.greenComponent > 0.5 && thumbnail.redComponent < 0.4)
    let betweenColumns = color(185, 40)
    check("thumbnail stays inside its 161pt grid column",
          min(betweenColumns.redComponent, betweenColumns.greenComponent, betweenColumns.blueComponent) > 0.9)
    let adjacentColumn = color(310, 40)
    check("image does not cover the adjacent attachment",
          min(adjacentColumn.redComponent, adjacentColumn.greenComponent, adjacentColumn.blueComponent) > 0.9)
    check("fixed viewport is preserved", view.bounds.width == 370 && view.bounds.height == 250)
    func click(in target: NSWindow, point: NSPoint) {
        for kind in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = NSEvent.mouseEvent(with: kind, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: target.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            target.sendEvent(event)
        }
    }
    click(in: window, point: NSPoint(x: 65, y: 185))
    RunLoop.main.run(until: Date().addingTimeInterval(0.5))
    check("thumbnail click presents preview sheet", window.attachedSheet != nil)
    if let sheet = window.attachedSheet {
        func captureSheet(_ name: String) throws -> NSColor {
            let content = sheet.contentView!
            content.layoutSubtreeIfNeeded()
            let pixels = content.bitmapImageRepForCachingDisplay(in: content.bounds)!
            content.cacheDisplay(in: content.bounds, to: pixels)
            try pixels.representation(using: .png, properties: [:])!
                .write(to: root.appendingPathComponent(name + ".png"))
            return pixels.colorAt(x: pixels.pixelsWide / 2, y: pixels.pixelsHigh / 2)!
                .usingColorSpace(.deviceRGB)!
        }
        _ = try captureSheet("clicked-preview")
        click(in: sheet, point: NSPoint(x: sheet.frame.width - 38, y: sheet.frame.height / 2))
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let missing = try captureSheet("clicked-next-missing")
        check("next selects missing-image failure state", missing.redComponent < 0.3 && missing.greenComponent < 0.3)
        click(in: sheet, point: NSPoint(x: 38, y: sheet.frame.height / 2))
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let restored = try captureSheet("clicked-previous")
        check("previous restores decoded image", restored.redComponent > 0.5 && restored.greenComponent > 0.5)
        click(in: sheet, point: NSPoint(x: sheet.frame.width - 38, y: sheet.frame.height - 38))
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        check("preview close dismisses sheet", window.attachedSheet == nil)
    }
    window.close()
    let composer = NSHostingView(rootView: ComposerAttachmentFixture(
        model: ComposerAttachmentModel(droppedPaths: [input.path]))
        .padding(20).frame(width: 220, height: 130, alignment: .topLeading)
        .background(Color.white).environment(\.colorScheme, .light))
    let composerWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 220, height: 130),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
    composerWindow.isReleasedWhenClosed = false
    composerWindow.contentView = composer
    composerWindow.orderBack(nil)
    RunLoop.main.run(until: Date().addingTimeInterval(0.4))
    composer.layoutSubtreeIfNeeded()
    let composerPixels = composer.bitmapImageRepForCachingDisplay(in: composer.bounds)!
    composer.cacheDisplay(in: composer.bounds, to: composerPixels)
    try composerPixels.representation(using: .png, properties: [:])!
        .write(to: root.appendingPathComponent("composer.png"))
    let composerColor = composerPixels.colorAt(
        x: 30 * composerPixels.pixelsWide / 220, y: 30 * composerPixels.pixelsHigh / 130)!
        .usingColorSpace(.deviceRGB)!
    check("real composer function renders thumbnail pixels", composerColor.greenComponent > 0.5 && composerColor.redComponent < 0.4)
    click(in: composerWindow, point: NSPoint(x: 55, y: 75))
    RunLoop.main.run(until: Date().addingTimeInterval(0.4))
    check("composer thumbnail click presents preview", composerWindow.attachedSheet != nil)
    if let sheet = composerWindow.attachedSheet {
        click(in: sheet, point: NSPoint(x: sheet.frame.width - 38, y: sheet.frame.height - 38))
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    }
    composerWindow.close()
    let preview = NSHostingView(rootView: ChatAttachmentImagePreview(
        attachments: [.init(path: input.path, name: "範例圖片")], initialPath: input.path)
        .frame(width: 900, height: 650))
    preview.frame = NSRect(x: 0, y: 0, width: 900, height: 650)
    let previewWindow = NSWindow(contentRect: preview.frame, styleMask: [.borderless],
                                 backing: .buffered, defer: false)
    previewWindow.isReleasedWhenClosed = false
    previewWindow.contentView = preview
    previewWindow.orderBack(nil)
    RunLoop.main.run(until: Date().addingTimeInterval(0.5))
    preview.layoutSubtreeIfNeeded()
    let expanded = preview.bitmapImageRepForCachingDisplay(in: preview.bounds)!
    preview.cacheDisplay(in: preview.bounds, to: expanded)
    try expanded.representation(using: .png, properties: [:])!
        .write(to: root.appendingPathComponent("live-expanded.png"))
    let center = expanded.colorAt(x: expanded.pixelsWide / 2, y: expanded.pixelsHigh / 2)!
        .usingColorSpace(.deviceRGB)!
    check("expanded production wrapper loads actual image", center.redComponent > 0.5 && center.greenComponent > 0.5)
    previewWindow.close()
    print("ATTACHMENTRENDERTEST RESULT passed=\(passed) failed=\(failed) skipped=0")
    exit(failed == 0 ? 0 : 1)
}
try MainActor.assumeIsolated { try runAttachmentRenderChecks() }
