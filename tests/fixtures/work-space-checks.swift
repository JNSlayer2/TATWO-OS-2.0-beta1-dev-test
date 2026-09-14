// Minimal collaborators only; the document, preview state and projection methods are production source.
enum BotLibraryError: Error { case invalid(String) }
struct ChatMessage {}
enum TatwoCodexReasoningEffort { case medium }
enum TatwoModelSpeedTier { case standard }
enum TatwoPermissionPreset { case askFirst }
enum ChatCollaborationLevel { case off }
struct ChatRouteChoice {
    let id = "fixture"
    let defaultEffort = TatwoCodexReasoningEffort.medium
    let defaultSpeedTier: TatwoModelSpeedTier? = .standard
    let allowedEfforts: [TatwoCodexReasoningEffort] = [.medium]
    let allowedSpeedTiers: [TatwoModelSpeedTier] = [.standard]
    static let all = [Self()]
}
enum TatwoChatCommandMode { case chat, cli }
@MainActor final class SpaceWorkspaceController {
    static let shared = SpaceWorkspaceController()
    var state: SpaceSetupPreviewState?
    var hasInvalidWorkspace = false
    // INSERT projection
}
@main struct Checks {
    @MainActor static func main() throws {
        let legacy = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
        let doc = try JSONDecoder().decode(SpaceWorkspaceDocument.self, from: legacy).validated()
        let saved = doc.domains["legacy"]!
        precondition(saved.tabOrder == [.bot, .chat, .cli, .browser])
        precondition(saved.disabledTabs == [.cli])
        precondition(saved.customTabs == [:])
        let roundTrip = try JSONDecoder().decode(SpaceWorkspaceDocument.self, from: JSONEncoder().encode(doc)).validated()
        precondition(roundTrip == doc)
        // User explicitly requires appending every missing builtin at decode, not only Browser.
        let missingBuiltins = Data(#"{"version":1,"domains":{"legacy":{"id":"legacy","tabOrder":[]}}}"#.utf8)
        let repaired = try JSONDecoder().decode(SpaceWorkspaceDocument.self, from: missingBuiltins).validated()
        precondition(repaired.domains["legacy"]!.tabOrder == SpaceManagedTab.allCases)
        var customDoc = doc
        let id = "MiXeD-Custom-ID"
        customDoc.domains["legacy"]!.customTabs = [id: "Design"]
        customDoc.domains["legacy"]!.tabOrder.append(SpaceManagedTab(rawValue: id)!)
        let customRoundTrip = try JSONDecoder().decode(SpaceWorkspaceDocument.self, from: JSONEncoder().encode(customDoc)).validated()
        precondition(customRoundTrip == customDoc)
        precondition(SpaceManagedTab(modeRawValue: id)!.modeRawValue == id)
        for corrupt in ["unknown", "duplicate", "missing", "collision", "disabled"] {
            var bad = customDoc
            switch corrupt {
            case "unknown": bad.domains["legacy"]!.tabOrder.append(SpaceManagedTab(rawValue: "foreign")!)
            case "duplicate": bad.domains["legacy"]!.tabOrder.append(.chat)
            case "missing": bad.domains["legacy"]!.tabOrder.removeLast()
            case "collision": bad.domains["legacy"]!.customTabs = ["Chat": "Collision"]
            default: bad.domains["legacy"]!.disabledTabs.insert(SpaceManagedTab(rawValue: "foreign")!)
            }
            do { _ = try bad.validated(); fatalError("accepted \(corrupt)") } catch {}
        }
        let state = SpaceSetupPreviewState.isEnabled ? SpaceSetupPreviewState.shared : SpaceSetupPreviewState()
        let domain = state.selectedDomain
        domain.screen = .settings
        var saves = 0
        domain.onPersist = { saves += 1 }
        domain.addWorkSpace()
        let tab = domain.tabs.last!
        precondition(tab.isCustom && domain.name(for: tab) == "Work Space 1")
        if case .settings = domain.screen {} else { fatalError("add navigated") }
        precondition(domain.interfaces.isEmpty && domain.bots.count == 1)
        domain.renameWorkSpace(tab, to: "Renamed")
        domain.moveTab(tab, offset: -1)
        domain.moveTab(tab, before: .chat)
        precondition(domain.tabs.first == tab && domain.name(for: tab) == "Renamed")
        domain.toggle(tab)
        precondition(!domain.visibleTabs.contains(tab))
        domain.toggle(tab)
        domain.addWorkSpace()
        precondition(domain.name(for: domain.tabs.last!) == "Work Space 2")
        precondition(saves == 7)
        precondition(state.domains[1].customTabs.isEmpty)
        let controller = SpaceWorkspaceController.shared
        controller.state = state
        precondition(controller.visibleModes.contains(.custom(tab.rawValue)))
        precondition(ChatRunMode.custom(tab.rawValue).displayName == "Renamed")
        domain.renameWorkSpace(tab, to: "")
        precondition(ChatRunMode.custom(tab.rawValue).displayName == "Work Space")
        domain.renameWorkSpace(tab, to: "  ")
        precondition(domain.name(for: tab) == "Work Space")
        domain.renameWorkSpace(tab, to: "Renamed")
        precondition(ChatRunMode(rawValue: "") == nil)
        for mode in ChatRunMode.allCases + [.custom(id)] { precondition(ChatRunMode(rawValue: mode.rawValue) == mode) }
        let browserEnabled = ProcessInfo.processInfo.environment["TATWO_BROWSER_WORKSPACE_PREVIEW"] == "1"
        precondition(controller.visibleModes.contains(.browser) == browserEnabled)
        precondition(controller.allows(.browser) == browserEnabled)
        domain.toggle(.browser)
        precondition(!controller.visibleModes.contains(.browser))
        controller.hasInvalidWorkspace = true
        precondition(controller.visibleModes.isEmpty && !controller.allows(.chat))
        print("work-space fixture: migration, roundtrip, invalid permutations, local add, rename, toggle, reorder, isolation, custom modes, browser=\(browserEnabled): PASS")
    }
}
