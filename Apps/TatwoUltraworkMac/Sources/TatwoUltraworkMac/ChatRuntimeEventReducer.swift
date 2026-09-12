import Foundation
import TatwoUltraworkCore

@MainActor
protocol ChatRuntimeEventReducer {
    func reduce(
        _ event: ChatCLIEvent,
        runID: String,
        runtimeAdapter: TatwoChatRuntimeAdapter,
        model: ChatPageModel
    )
}

struct DefaultChatRuntimeEventReducer: ChatRuntimeEventReducer {
    func reduce(
        _ event: ChatCLIEvent,
        runID: String,
        runtimeAdapter: TatwoChatRuntimeAdapter,
        model: ChatPageModel
    ) {
        if runtimeAdapter == .nativeAgent {
            model.consumeNativeRuntimeEvent(event, runID: runID)
        } else if runtimeAdapter == .minimaxDirect
                    || runtimeAdapter == .unavailable
        {
            model.consumeBuiltInDirectRuntimeEvent(event, runID: runID)
        } else {
            model.consumeLegacyRuntimeEvent(event, runID: runID)
        }
    }
}
