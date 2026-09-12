import Foundation
import TatwoUltraworkCore

/// Automation seam for the exec arena (tests/exec-arena) and any external
/// driver that wants to act like a human in the composer. It only calls the
/// same entry points the UI uses (create project, new chat, send, stop) and
/// reads back the transcript state; there is no second runtime.
extension ChatPageModel {
    static weak var automationInstance: ChatPageModel?

    func automationCreateProject(workdir: String, name: String?) -> UUID? {
        let folderURL = URL(fileURLWithPath: workdir, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folderURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else { return nil }
        return createOrSelectProject(folderURL: folderURL, preferredName: name)
    }

    /// With a project id the thread is created inside that project (turns run
    /// in its workdir); without one it is a standalone chat (chat-workspace).
    func automationNewThread(projectID: String?) -> UUID? {
        if let projectID, let uuid = UUID(uuidString: projectID) {
            return createThread(inProject: uuid)
        }
        createUserOwnedChat()
        return selectedThreadID
    }

    /// Returns true when a turn actually started.
    func automationSend(text: String, modelID: String?) -> Bool {
        guard !isRunning else { return false }
        if let modelID, !modelID.isEmpty {
            setSingleModel(modelID)
        }
        prompt = text
        send()
        return isRunning
    }

    func automationStop() {
        stop()
    }

    func automationStatus() -> JSONValue {
        let last = messages.last
        // The final reply is the last assistant *message*; work-timeline /
        // thinking items are assistant rows too but carry no answer text.
        let lastAssistant = messages.last(where: {
            $0.role == .assistant && $0.eventKind == .message
        })
        return .object([
            "threadID": .string(selectedThreadID?.uuidString ?? ""),
            "projectID": .string(selectedProjectID?.uuidString ?? ""),
            "model": .string(selectedModel),
            "isRunning": .bool(isRunning),
            "messageCount": .number(Double(messages.count)),
            "lastRole": .string(last?.role.storageValue ?? ""),
            "lastStatus": .string(last?.status ?? ""),
            "lastAssistantStatus": .string(lastAssistant?.status ?? ""),
            "lastAssistantText": .string(String((lastAssistant?.text ?? "").suffix(6000))),
        ])
    }
}
