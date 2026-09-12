import Foundation

enum CLIFixture {
    static let tabID = UUID(uuidString: "C1111111-1111-1111-1111-111111111111")!
    static let tabs = [TatwoCLITab(id: tabID, title: "CLI")]
    static let terminalLines = [
        TatwoTerminalLine(id: 0, spans: [TatwoTerminalSpan(text: "tatwo2 fixture terminal", foreground: .brightBlack)]),
        TatwoTerminalLine(id: 1, spans: [TatwoTerminalSpan(text: "等待 CLI 專案", foreground: .default)])
    ]
    static let session = TatwoNativePTYTerminalSession(
        launch: TatwoNativeTerminalLaunch(workingDirectory: URL(fileURLWithPath: NSTemporaryDirectory())),
        onUpdate: { _ in },
        onStatus: { _ in }
    )
}
