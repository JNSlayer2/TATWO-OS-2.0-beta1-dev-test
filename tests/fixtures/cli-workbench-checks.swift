import AppKit

@MainActor func checkCLIWorkbench() throws {
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.prohibited)
    let destination = URL(fileURLWithPath: CommandLine.arguments[1])
    var failures = 0
    func check(_ name: String, _ value: Bool) {
        print("CLIWORKBENCH \(value ? "PASS" : "FAIL") \(name)")
        if !value { failures += 1 }
    }
    let id = CLIWorkbenchFixtureState.id
    let four = CLIWorkbenchFixtureState(scene: .four).tabs[0].layout!
    let projection = four.projection(in: CGSize(width: 1160, height: 760), focused: id(1), maximized: nil)
    check("four panes, three dividers", projection.panes.count == 4 && projection.dividers.count == 3)
    check("four panes visible", projection.panes.allSatisfy(\.isVisible))
    check("pane identity remains unique", Set(projection.panes.map(\.id)).count == 4)
    check("all panes remain usable", projection.panes.allSatisfy {
        $0.frame.width >= 360 && $0.frame.height >= 180
    })
    for a in projection.panes {
        check("pane has no overlap \(a.id)", projection.panes.filter { $0.id != a.id }.allSatisfy {
            !a.frame.intersects($0.frame)
        })
    }
    check("divider has at least 6pt hit area", projection.dividers.allSatisfy {
        ($0.axis == .horizontal ? $0.frame.width : $0.frame.height) >= 6
    })
    let narrow = four.projection(in: CGSize(width: 700, height: 620), focused: id(3), maximized: nil)
    check("narrow focus without losing panes", narrow.isCompact && narrow.panes.count == 4 &&
          narrow.panes.filter(\.isVisible).map(\.id) == [id(3)] && narrow.dividers.isEmpty)
    let zoom = four.projection(in: CGSize(width: 1160, height: 760), focused: id(1), maximized: id(4))
    check("maximize retains all identities", zoom.panes.map(\.id) == four.paneIDs &&
          zoom.panes.filter(\.isVisible).map(\.id) == [id(4)])
    let resized = four.settingRatio(splitID: id(20), ratio: 0.62)
    check("drag does not replace pane IDs", resized.paneIDs == four.paneIDs)
    check("invalid ratio ignored", four.settingRatio(splitID: id(20), ratio: .nan) == four)
    check("layout Codable roundtrip", try JSONDecoder().decode(CLIWorkbenchLayout.self,
        from: JSONEncoder().encode(resized)) == resized)
    check("removing leaf collapses split", four.removing(id(3))?.paneIDs == [id(1), id(2), id(4)])
    check("split cannot duplicate pane identity", four.splitting(id(1), newPane: id(2), axis: .horizontal) == four)

    var state = CLIWorkbenchFixtureState(scene: .four)
    check("both editing options default off", !state.editingOptions.deleteToLineStart && !state.editingOptions.deletePreviousWord)
    state.send(.setEditingOptions(.init(deleteToLineStart: true, deletePreviousWord: false)))
    check("line shortcut independent", state.editingOptions.deleteToLineStart && !state.editingOptions.deletePreviousWord)
    state.send(.setEditingOptions(.init(deleteToLineStart: false, deletePreviousWord: true)))
    check("word shortcut independent", !state.editingOptions.deleteToLineStart && state.editingOptions.deletePreviousWord)
    let before = state.tabs
    state.send(.requestClosePane(id(1)))
    state.send(.resolveClose(.cancel))
    check("cancel preserves layout", before == state.tabs)
    state.send(.requestClosePane(id(1)))
    state.send(.resolveClose(.background))
    check("background stays findable", state.panes.first { $0.id == id(1) }?.isBackground == true &&
          state.tabs[0].layout?.paneIDs.contains(id(1)) == false)
    state.send(.reattach(id(1)))
    check("reattach preserves identity", state.tabs.last?.layout?.paneIDs == [id(1)])
    state.send(.requestClosePane(id(1)))
    state.send(.resolveClose(.terminate))
    let count = state.tabs.count
    state.send(.reattach(id(1)))
    check("dead pane is never relaunched by fixture", state.tabs.count == count &&
          state.panes.first { $0.id == id(1) }?.state == .exited)
    state.send(.createTab(engine: "codex"))
    check("new tab remains a fixture, status unknown", state.panes.last?.state == .unknown)

    func render(_ state: CLIWorkbenchFixtureState, theme: TatwoTheme, name: String, size: CGSize) throws {
        TatwoActivePalette.current = theme.palette // in-memory in the fixture process, no settings I/O.
        let content = CLIWorkbenchFixtureView(state: state, appearance: .osTheme(theme.palette))
            .frame(width: size.width, height: size.height)
        let view = NSHostingView(rootView: content)
        view.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.08))
        let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])!.write(to: destination.appendingPathComponent(name + ".png"))
        print("CLIWORKBENCH RENDER \(name) points=\(Int(size.width))x\(Int(size.height)) pixels=\(bitmap.pixelsWide)x\(bitmap.pixelsHigh)")
        check("render bounds \(name)", bitmap.pixelsWide >= Int(size.width) && bitmap.pixelsHigh >= Int(size.height))
        if state.pendingCloseTitle == nil, let tab = state.tabs.first(where: { $0.id == state.selectedTabID }),
           let layout = tab.layout {
            let inset = CLIWorkbenchMetrics.inset
            let origin = CGPoint(x: CLIWorkbenchFixtureView.sidebarWidth + CLIWorkbenchMetrics.hairline + inset,
                                 y: CLIWorkbenchMetrics.tabHeight * 2 + inset)
            let canvasSize = CGSize(
                width: size.width - origin.x - inset,
                height: size.height - origin.y - inset - CLIWorkbenchMetrics.footer -
                    (layout.paneIDs.count > 1 ? CLIWorkbenchMetrics.paneHeader : 0))
            let expected = layout.projection(in: canvasSize, focused: tab.focusedPaneID,
                                            maximized: tab.maximizedPaneID)
            let surface = NSColor(theme.palette.surfaceFill).usingColorSpace(.deviceRGB)!
            // Raster evidence, not merely layout math: catches offset panes clipped by a small ZStack.
            for pane in expected.panes where pane.isVisible {
                let x = Int((origin.x + pane.frame.midX) / size.width * CGFloat(bitmap.pixelsWide))
                let y = Int((origin.y + pane.frame.maxY - 24) / size.height * CGFloat(bitmap.pixelsHigh))
                let actual = bitmap.colorAt(x: x, y: y)!.usingColorSpace(.deviceRGB)!
                let difference = abs(actual.redComponent - surface.redComponent) +
                    abs(actual.greenComponent - surface.greenComponent) +
                    abs(actual.blueComponent - surface.blueComponent)
                check("visible pane has real surface pixels \(name) \(pane.id)", difference < 0.04)
            }
        }
        window.close() // never orderFront, never launch an OS App or terminal.
    }
    for theme in [TatwoTheme.aurora, TatwoTheme.fable5] {
        for size in [CGSize(width: 1440, height: 900), CGSize(width: 980, height: 720)] {
            for scene in CLIWorkbenchFixtureState.Scene.allCases {
                let name = "\(theme.id.rawValue)-\(Int(size.width))-\(scene.rawValue)"
                try autoreleasepool {
                    try render(.init(scene: scene), theme: theme, name: name, size: size)
                }
            }
        }
    }
    print("CLIWORKBENCH RESULT failed=\(failures) (presentation only; no terminal acceptance)")
    exit(failures == 0 ? 0 : 1)
}

try MainActor.assumeIsolated { try checkCLIWorkbench() }
