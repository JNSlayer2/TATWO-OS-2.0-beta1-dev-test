import Foundation

public enum TatwoChatSearchIndexBuilder {
  public static func build(
    projects: [TatwoNativeChatProject],
    history: TatwoCLICommandHistoryBook
  ) -> TatwoChatSearchIndex {
    let messages = projects.flatMap { project in
      project.threads.flatMap { thread in
        (thread.messages ?? []).map { message in
          TatwoChatSearchMessage(
            projectID: project.id,
            threadID: thread.id,
            messageID: message.id,
            title: thread.title,
            role: message.role,
            text: message.text,
            timestamp: message.createdAt)
        }
      }
    }

    return TatwoChatSearchIndex(messages: messages, history: history)
  }
}
