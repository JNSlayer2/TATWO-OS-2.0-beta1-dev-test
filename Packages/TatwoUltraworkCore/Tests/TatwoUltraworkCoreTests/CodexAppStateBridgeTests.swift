import Foundation
import Testing
@testable import TatwoUltraworkCore

@Suite("Codex App state bridge")
struct CodexAppStateBridgeTests {
  @Test("detects literal external-volume Codex sources")
  func detectsExternalVolumeCodexSources() {
    let external = TatwoCodexAppStateBridge.SourcePaths(
      stateDatabaseURL: URL(fileURLWithPath: "/Volumes/External/CodexHome/state_5.sqlite"),
      globalStateURL: URL(fileURLWithPath: "/Volumes/External/CodexHome/.codex-global-state.json"))
    let local = TatwoCodexAppStateBridge.SourcePaths(
      stateDatabaseURL: URL(fileURLWithPath: "/Users/example/.codex/state_5.sqlite"),
      globalStateURL: URL(fileURLWithPath: "/Users/example/.codex/.codex-global-state.json"))

    #expect(external.requiresExternalVolumeOptIn)
    #expect(!local.requiresExternalVolumeOptIn)
  }

  @Test("detects external volume through symlinked state and global paths")
  func detectsExternalVolumeThroughSymlinkedSourcePaths() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("tatwo-codex-external-symlink-\(UUID().uuidString)", isDirectory: true)
    let localHome = root.appendingPathComponent("local-home", isDirectory: true)
    let externalHome = root.appendingPathComponent("external-home", isDirectory: true)
    try FileManager.default.createDirectory(at: localHome, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createSymbolicLink(
      atPath: externalHome.path,
      withDestinationPath: "/Volumes/External/CodexHome")

    let externalState = TatwoCodexAppStateBridge.SourcePaths(
      stateDatabaseURL: externalHome.appendingPathComponent("state_5.sqlite"),
      globalStateURL: localHome.appendingPathComponent(".codex-global-state.json"))
    let externalGlobal = TatwoCodexAppStateBridge.SourcePaths(
      stateDatabaseURL: localHome.appendingPathComponent("state_5.sqlite"),
      globalStateURL: externalHome.appendingPathComponent(".codex-global-state.json"))

    #expect(externalState.requiresExternalVolumeOptIn)
    #expect(externalGlobal.requiresExternalVolumeOptIn)
  }

  @Test("keeps purely local source paths off the external-volume gate")
  func keepsPurelyLocalSourcePathsLocal() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("tatwo-codex-local-source-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let local = TatwoCodexAppStateBridge.SourcePaths(
      stateDatabaseURL: root.appendingPathComponent("state_5.sqlite"),
      globalStateURL: root.appendingPathComponent(".codex-global-state.json"))

    #expect(!local.requiresExternalVolumeOptIn)
  }

  @Test("detects nested relative symlinks that end on an external volume")
  func detectsNestedExternalVolumeSymlinks() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("tatwo-codex-nested-symlink-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let outerLink = root.appendingPathComponent("outer-home", isDirectory: true)
    let innerLink = root.appendingPathComponent("inner-home", isDirectory: true)
    try FileManager.default.createSymbolicLink(
      atPath: innerLink.path,
      withDestinationPath: "/Volumes/External/CodexHome")
    try FileManager.default.createSymbolicLink(
      atPath: outerLink.path,
      withDestinationPath: "inner-home")

    let nested = TatwoCodexAppStateBridge.SourcePaths(
      stateDatabaseURL: outerLink.appendingPathComponent("state_5.sqlite"),
      globalStateURL: outerLink.appendingPathComponent(".codex-global-state.json"))

    #expect(nested.requiresExternalVolumeOptIn)
  }

  @Test("external mirror does not invoke the loader before opt in")
  func externalMirrorSkipsLoaderBeforeOptIn() {
    let paths = TatwoCodexAppStateBridge.SourcePaths(
      stateDatabaseURL: URL(fileURLWithPath: "/Volumes/External/CodexHome/state_5.sqlite"),
      globalStateURL: URL(fileURLWithPath: "/Volumes/External/CodexHome/.codex-global-state.json"))
    var loadCount = 0

    let result = TatwoCodexAppStateBridge.loadDocumentOverlayFailSoft(
      sourcePaths: paths,
      externalVolumeOptIn: false
    ) {
      loadCount += 1
      throw NSError(domain: "unexpected-read", code: 1)
    }

    #expect(result.status == .notEnabled)
    #expect(result.document == nil)
    #expect(loadCount == 0)
  }

  @Test("mirror read failure degrades without throwing")
  func mirrorReadFailureDegradesWithoutThrowing() {
    let paths = TatwoCodexAppStateBridge.SourcePaths(
      stateDatabaseURL: URL(fileURLWithPath: "/Users/example/.codex/state_5.sqlite"),
      globalStateURL: URL(fileURLWithPath: "/Users/example/.codex/.codex-global-state.json"))
    var loadCount = 0

    let result = TatwoCodexAppStateBridge.loadDocumentOverlayFailSoft(
      sourcePaths: paths,
      externalVolumeOptIn: false
    ) {
      loadCount += 1
      throw NSError(domain: "denied", code: 13)
    }

    #expect(result.status == .unavailable)
    #expect(result.document == nil)
    #expect(loadCount == 1)
  }

  @Test("missing local mirror source degrades before invoking sqlite")
  func missingLocalMirrorSourceDegradesBeforeSQLite() {
    let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent(
        "tatwo-codex-missing-local-source-\(UUID().uuidString)",
        isDirectory: true)
    let bridge = TatwoCodexAppStateBridge(
      sourcePaths: .init(
        stateDatabaseURL: root.appendingPathComponent("state_5.sqlite"),
        globalStateURL: root.appendingPathComponent(".codex-global-state.json")))

    let result = bridge.loadDocumentOverlayFailSoft(
      externalVolumeOptIn: false,
      cacheRootURL: nil)

    #expect(result.status == .unavailable)
    #expect(result.document == nil)
    #expect(result.failure == .volumeAbsent)
    #expect(!FileManager.default.fileExists(
      atPath: bridge.sourcePaths.stateDatabaseURL.path))
  }

  @Test("available local mirror with zero rows remains loaded")
  func availableEmptyLocalMirrorRemainsLoaded() {
    let paths = TatwoCodexAppStateBridge.SourcePaths(
      stateDatabaseURL: URL(
        fileURLWithPath: "/Users/example/.codex/state_5.sqlite"),
      globalStateURL: URL(
        fileURLWithPath: "/Users/example/.codex/.codex-global-state.json"))
    var loadCount = 0
    let expected = TatwoNativeChatStoreDocument()

    let result = TatwoCodexAppStateBridge.loadDocumentOverlayFailSoft(
      sourcePaths: paths,
      externalVolumeOptIn: false,
      sourceAccessCheck: { true },
      cacheRootURL: nil
    ) {
      loadCount += 1
      return expected
    }

    #expect(result.status == .loaded)
    #expect(result.document == expected)
    #expect(loadCount == 1)
  }

  @Test("public local mirror loads a real regular SQLite source")
  func publicLocalMirrorLoadsRealSQLiteSource() async throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent(
        "tatwo-codex-public-local-source-\(UUID().uuidString)",
        isDirectory: true)
    try FileManager.default.createDirectory(
      at: root,
      withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let databaseURL = root.appendingPathComponent("state_5.sqlite")
    let globalStateURL = root.appendingPathComponent(".codex-global-state.json")
    let threadID = "019fd746-7f56-77a1-aa42-7a7e3466971e"
    try runSQLite(db: databaseURL, sql: """
      CREATE TABLE threads (
        id TEXT PRIMARY KEY,
        rollout_path TEXT NOT NULL,
        cwd TEXT NOT NULL,
        title TEXT NOT NULL,
        source TEXT NOT NULL,
        thread_source TEXT,
        preview TEXT NOT NULL DEFAULT '',
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL,
        created_at_ms INTEGER,
        updated_at_ms INTEGER,
        recency_at_ms INTEGER NOT NULL DEFAULT 0,
        archived INTEGER NOT NULL DEFAULT 0,
        model TEXT
      );
      INSERT INTO threads (
        id, rollout_path, cwd, title, source, thread_source, preview,
        created_at, updated_at, created_at_ms, updated_at_ms, recency_at_ms,
        archived, model
      ) VALUES (
        '\(threadID)', '/tmp/public-local-rollout.jsonl', '',
        'Public local mirror', 'user', 'user', 'local preview',
        100, 200, 100000, 200000, 200000, 0, 'gpt-5.5'
      );
      """)
    try Data("""
      {
        "projectless-thread-ids": ["\(threadID)"]
      }
      """.utf8).write(to: globalStateURL)

    let bridge = TatwoCodexAppStateBridge(
      sourcePaths: .init(
        stateDatabaseURL: databaseURL,
        globalStateURL: globalStateURL))
    let result = await Task.detached {
      bridge.loadDocumentOverlayFailSoft(
        externalVolumeOptIn: false,
        cacheRootURL: nil)
    }.value

    #expect(result.status == .loaded)
    #expect(result.failure == nil)
    #expect(result.document?.threads.compactMap(\.codexSessionID) == [threadID])
  }

  @Test("invalid local sqlite query degrades without an empty loaded mirror")
  func invalidLocalSQLiteDegradesWithoutEmptyMirror() async throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent(
        "tatwo-codex-invalid-local-sqlite-\(UUID().uuidString)",
        isDirectory: true)
    try FileManager.default.createDirectory(
      at: root,
      withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let databaseURL = root.appendingPathComponent("state_5.sqlite")
    try Data("not-a-sqlite-database".utf8).write(to: databaseURL)
    let bridge = TatwoCodexAppStateBridge(
      sourcePaths: .init(
        stateDatabaseURL: databaseURL,
        globalStateURL: root.appendingPathComponent(".codex-global-state.json")))

    let result = await Task.detached {
      bridge.loadDocumentOverlayFailSoft(
        externalVolumeOptIn: false,
        cacheRootURL: nil)
    }.value

    #expect(result.status == .unavailable)
    #expect(result.document == nil)
    #expect(result.failure == .ioError)
  }

  @Test("external mirror invokes the loader after opt in")
  func externalMirrorAttemptsLoadAfterOptIn() {
    let paths = TatwoCodexAppStateBridge.SourcePaths(
      stateDatabaseURL: URL(fileURLWithPath: "/Volumes/External/CodexHome/state_5.sqlite"),
      globalStateURL: URL(fileURLWithPath: "/Volumes/External/CodexHome/.codex-global-state.json"))
    let expected = TatwoNativeChatStoreDocument()
    var loadCount = 0

    let result = TatwoCodexAppStateBridge.loadDocumentOverlayFailSoft(
      sourcePaths: paths,
      externalVolumeOptIn: true
    ) {
      loadCount += 1
      return expected
    }

    #expect(result.status == .loaded)
    #expect(result.document == expected)
    #expect(loadCount == 1)
  }

  @Test("denied external source access degrades and does not invoke sqlite")
  func deniedExternalSourceAccessDegradesBeforeSQLite() {
    let paths = TatwoCodexAppStateBridge.SourcePaths(
      stateDatabaseURL: URL(fileURLWithPath: "/Volumes/External/CodexHome/state_5.sqlite"),
      globalStateURL: URL(fileURLWithPath: "/Volumes/External/CodexHome/.codex-global-state.json"))
    var loadCount = 0

    let result = TatwoCodexAppStateBridge.loadDocumentOverlayFailSoft(
      sourcePaths: paths,
      externalVolumeOptIn: true,
      sourceAccessCheck: { false }
    ) {
      loadCount += 1
      return TatwoNativeChatStoreDocument()
    }

    #expect(result.status == .unavailable)
    #expect(result.document == nil)
    #expect(loadCount == 0)
  }

  @Test("mirror keeps a last-good document when the source later disappears")
  func mirrorUsesLastGoodCacheAfterSourceDisappears() throws {
    let cacheRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("tatwo-mirror-cache-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: cacheRoot) }
    let paths = TatwoCodexAppStateBridge.SourcePaths(
      stateDatabaseURL: URL(fileURLWithPath: "/tmp/codex-cache/state.sqlite"),
      globalStateURL: URL(fileURLWithPath: "/tmp/codex-cache/global.json"))
    let expected = TatwoNativeChatStoreDocument()

    let fresh = TatwoCodexAppStateBridge.loadDocumentOverlayFailSoft(
      sourcePaths: paths,
      externalVolumeOptIn: false,
      cacheRootURL: cacheRoot
    ) {
      expected
    }
    #expect(fresh.status == .loaded)
    #expect(!fresh.isStale)

    let stale = TatwoCodexAppStateBridge.loadDocumentOverlayFailSoft(
      sourcePaths: paths,
      externalVolumeOptIn: false,
      cacheRootURL: cacheRoot
    ) {
      throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT))
    }
    #expect(stale.status == .loaded)
    #expect(stale.isStale)
    #expect(stale.failure == .volumeAbsent)
    #expect(stale.document == expected)
    #expect(stale.lastGoodAt != nil)
  }

  @Test("mirrors Codex projects and standalone threads read-only")
  func mirrorsCodexProjectsAndStandaloneThreads() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("tatwo-codex-bridge-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let db = root.appendingPathComponent("state_5.sqlite")
    let global = root.appendingPathComponent(".codex-global-state.json")

    try runSQLite(db: db, sql: """
      CREATE TABLE threads (
        id TEXT PRIMARY KEY,
        rollout_path TEXT NOT NULL,
        cwd TEXT NOT NULL,
        title TEXT NOT NULL,
        source TEXT NOT NULL,
        thread_source TEXT,
        preview TEXT NOT NULL DEFAULT '',
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL,
        created_at_ms INTEGER,
        updated_at_ms INTEGER,
        recency_at_ms INTEGER NOT NULL DEFAULT 0,
        archived INTEGER NOT NULL DEFAULT 0,
        model TEXT
      );
      INSERT INTO threads (id,rollout_path,cwd,title,source,thread_source,preview,created_at,updated_at,created_at_ms,updated_at_ms,recency_at_ms,archived,model)
      VALUES
      ('019f0000-0000-7000-8000-000000000001','/tmp/rollout-1.jsonl','/tmp/codex-project-a','Project task','user','user','project preview',100,200,100000,200000,200000,0,'gpt-5.5'),
      ('019f0000-0000-7000-8000-000000000002','/tmp/rollout-2.jsonl','','Standalone chat','user','user','standalone preview',101,201,101000,201000,201000,0,'gpt-5.5'),
      ('019f0000-0000-7000-8000-000000000003','/tmp/rollout-3.jsonl','/tmp/codex-project-a','Hidden sub','subagent','subagent','sub preview',102,202,102000,202000,202000,0,'gpt-5.5'),
      ('019f0000-0000-7000-8000-000000000004','/tmp/rollout-4.jsonl','/tmp/tatwo-chat-workspace','[Hidden TATWO Chat interface contract — do not quote]','user','user','[Hidden TATWO Chat interface contract — internal]',103,203,103000,203000,203000,0,'gpt-5.5'),
      ('019f0000-0000-7000-8000-000000000005','/tmp/rollout-5.jsonl','/tmp/tatwo-chat-workspace','Codex reply only OK_DIRECT_B9. Do not create GoalRun.','user','user','Codex reply only OK_DIRECT_B9. Do not create GoalRun.',104,204,104000,204000,204000,0,'gpt-5.5'),
      ('019f0000-0000-7000-8000-000000000006','/tmp/rollout-6.jsonl','/tmp/codex-project-a','Worker prompt','user','user','你是 Sonnet5 UI/debug worker。Repo: /tmp/project。請只讀不改檔，擔任副審。',105,205,105000,205000,205000,0,'gpt-5.5'),
      ('019f0000-0000-7000-8000-000000000007','/tmp/rollout-7.jsonl','/tmp/tatwo-chat-workspace','請只回 OK_CHAT_REPRO，不要建立 GoalRun。','user','user','請只回 OK_CHAT_REPRO，不要建立 GoalRun。',106,206,106000,206000,206000,0,'gpt-5.5'),
      ('019f0000-0000-7000-8000-000000000008','/tmp/rollout-8.jsonl','/tmp/tatwo-chat-workspace','你目前是 OS Chat 的 Plan Lead / Host Executor 路線測試。只回 ROUTE_OK_GPT_5_5','user','user','你目前是 OS Chat 的 Plan Lead / Host Executor 路線測試。只回 ROUTE_OK_GPT_5_5',107,207,107000,207000,207000,0,'gpt-5.5'),
      ('019f0000-0000-7000-8000-000000000009','/tmp/rollout-9.jsonl','/tmp/unsaved-worktree','Unsaved old project task','user','user','old worktree preview',108,208,108000,208000,208000,0,'gpt-5.5');
      """)

    let globalJSON = """
      {
        "project-order": ["/tmp/codex-project-a"],
        "electron-saved-workspace-roots": ["/tmp/codex-project-a"],
        "thread-project-assignments": {
          "019f0000-0000-7000-8000-000000000001": {"projectKind":"local","projectId":"/tmp/codex-project-a","path":"/tmp/codex-project-a"}
        },
        "thread-workspace-root-hints": {},
        "projectless-thread-ids": ["019f0000-0000-7000-8000-000000000002"],
        "sidebar-project-thread-orders": {
          "/tmp/codex-project-a": {
            "019f0000-0000-7000-8000-000000000001": {"sortKey": 100}
          }
        }
      }
      """
    try globalJSON.data(using: .utf8)!.write(to: global)

    let bridge = TatwoCodexAppStateBridge(
      sourcePaths: .init(stateDatabaseURL: db, globalStateURL: global),
      maxThreadRows: 10,
      maxThreadsPerProject: 10,
      maxStandaloneThreads: 10
    )
    let document = try bridge.loadDocumentOverlay()

    #expect(document.projects.count == 1)
    #expect(document.projects.first?.workdir == "/tmp/codex-project-a")
    #expect(document.projects.first?.threads.map(\.codexSessionID) == ["019f0000-0000-7000-8000-000000000001"])
    #expect(document.threads.map(\.codexSessionID) == ["019f0000-0000-7000-8000-000000000002"])
    #expect(document.threads.first?.mirroredCodexWorkspacePath == nil)
    #expect(
      document.threads.first?.sourceMarker
        == TatwoNativeChatThreadSourceMarker.codexAppMirror)
  }

  @Test("keeps a visible Tatwo Chat session when Codex omits its projectless marker")
  func keepsTatwoChatSessionWithoutProjectlessMarker() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("tatwo-codex-chat-recovery-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let db = root.appendingPathComponent("state_5.sqlite")
    let global = root.appendingPathComponent(".codex-global-state.json")
    let tatwoChatWorkspace = root
      .appendingPathComponent("Library", isDirectory: true)
      .appendingPathComponent("Application Support", isDirectory: true)
      .appendingPathComponent("Tatwo Ultrawork", isDirectory: true)
      .appendingPathComponent("chat-workspace", isDirectory: true)
    let targetThreadID = "019fc23e-6443-7b93-b886-0c2298cc7c13"

    try runSQLite(db: db, sql: """
      CREATE TABLE threads (
        id TEXT PRIMARY KEY,
        rollout_path TEXT NOT NULL,
        cwd TEXT NOT NULL,
        title TEXT NOT NULL,
        source TEXT NOT NULL,
        thread_source TEXT,
        preview TEXT NOT NULL DEFAULT '',
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL,
        created_at_ms INTEGER,
        updated_at_ms INTEGER,
        recency_at_ms INTEGER NOT NULL DEFAULT 0,
        archived INTEGER NOT NULL DEFAULT 0,
        model TEXT
      );
      INSERT INTO threads (
        id,rollout_path,cwd,title,source,thread_source,preview,
        created_at,updated_at,created_at_ms,updated_at_ms,recency_at_ms,archived,model
      )
      VALUES (
        '\(targetThreadID)',
        '/tmp/rollout.jsonl',
        '\(tatwoChatWorkspace.path)',
        '測試工作階段 LUNA-AUG02-01',
        'user',
        'user',
        '同一 session 多模型辦公壓測',
        100,200,100000,200000,200000,0,'gpt-5.6-sol'
      );
      """)
    try """
      {
        "project-order": [],
        "electron-saved-workspace-roots": [],
        "thread-project-assignments": {},
        "thread-workspace-root-hints": {},
        "projectless-thread-ids": [],
        "sidebar-project-thread-orders": {}
      }
      """.data(using: .utf8)!.write(to: global)

    let bridge = TatwoCodexAppStateBridge(
      sourcePaths: .init(stateDatabaseURL: db, globalStateURL: global),
      maxThreadRows: 10,
      maxThreadsPerProject: 10,
      maxStandaloneThreads: 10)
    let document = try bridge.loadDocumentOverlay()

    #expect(document.projects.isEmpty)
    #expect(document.threads.count == 1)
    #expect(document.threads.first?.codexSessionID == targetThreadID)
    #expect(document.threads.first?.title == "測試工作階段 LUNA-AUG02-01")
    #expect(
      document.threads.first?.mirroredCodexWorkspacePath
        == tatwoChatWorkspace.standardizedFileURL.path)
    #expect(
      document.threads.first?.sourceMarker
        == TatwoNativeChatThreadSourceMarker.codexAppMirror)
  }

  @Test("loads a compact Codex rollout transcript on demand")
  func loadsCompactCodexRolloutTranscript() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("tatwo-codex-transcript-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let db = root.appendingPathComponent("state_5.sqlite")
    let global = root.appendingPathComponent(".codex-global-state.json")
    let rollout = root.appendingPathComponent("rollout.jsonl")
    let threadID = "019f0000-0000-7000-8000-000000000111"

    let rolloutText = """
      {"timestamp":"2026-07-09T01:00:00.000Z","type":"response_item","payload":{"type":"message","role":"developer","content":[{"type":"input_text","text":"hidden"}]}}
      {"timestamp":"2026-07-09T01:00:01.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"[Hidden TATWO Chat interface contract]\\nprivate interface\\n[/Hidden TATWO Chat interface contract]\\n\\n你好"}],"internal_chat_message_metadata_passthrough":{"turn_id":"turn-a"}}}
      {"timestamp":"2026-07-09T01:00:02.000Z","type":"response_item","payload":{"type":"message","id":"msg-a","role":"assistant","content":[{"type":"output_text","text":"可以，這是回覆。"}],"internal_chat_message_metadata_passthrough":{"turn_id":"turn-a"}}}
      {"timestamp":"2026-07-09T01:00:03.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Conversation history from this same Tatwo thread:\\nbridgePolicy=capped-stateless; includedMessages=1; omittedMessages=0; maxCharacters=120000\\n[assistant] old answer\\n\\nCurrent user request:\\n[Hidden Codex-style Goal state]\\nprivate goal\\n[/Hidden Codex-style Goal state]\\n\\nKeep current request."}],"internal_chat_message_metadata_passthrough":{"turn_id":"turn-b"}}}
      {"timestamp":"2026-07-09T01:00:04.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"<codex_delegation>\\n<source_thread_id>019fb652-a553-7890-b177-b939073e4f0d</source_thread_id>\\n<input>Keep delegated request.</input>\\n</codex_delegation>"}],"internal_chat_message_metadata_passthrough":{"turn_id":"turn-c"}}}
      {"timestamp":"2026-07-09T01:00:05.000Z","type":"response_item","payload":{"type":"function_call_output","output":"ignored"}}
      """
    try rolloutText.data(using: .utf8)!.write(to: rollout)

    try runSQLite(db: db, sql: """
      CREATE TABLE threads (
        id TEXT PRIMARY KEY,
        rollout_path TEXT NOT NULL,
        cwd TEXT NOT NULL,
        title TEXT NOT NULL,
        source TEXT NOT NULL,
        thread_source TEXT,
        preview TEXT NOT NULL DEFAULT '',
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL,
        created_at_ms INTEGER,
        updated_at_ms INTEGER,
        recency_at_ms INTEGER NOT NULL DEFAULT 0,
        archived INTEGER NOT NULL DEFAULT 0,
        model TEXT
      );
      INSERT INTO threads (id,rollout_path,cwd,title,source,thread_source,preview,created_at,updated_at,created_at_ms,updated_at_ms,recency_at_ms,archived,model)
      VALUES ('\(threadID)','\(rollout.path)','/tmp/codex-project-a','Transcript task','user','user','preview',100,200,100000,200000,200000,0,'gpt-5.5');
      """)
    try "{}".data(using: .utf8)!.write(to: global)

    let bridge = TatwoCodexAppStateBridge(
      sourcePaths: .init(stateDatabaseURL: db, globalStateURL: global),
      maxThreadRows: 1,
      maxThreadsPerProject: 1,
      maxStandaloneThreads: 1)

    let messages = try bridge.loadTranscript(threadID: threadID, maxMessages: 8)
    #expect(messages.map(\.role) == ["user", "assistant", "user", "user"])
    #expect(
      messages.map(\.text)
        == [
          "你好",
          "可以，這是回覆。",
          "Keep current request.",
          "Keep delegated request."
        ])
  }

  @Test("refuses to launch sqlite subprocesses from the main thread")
  @MainActor
  func refusesMainThreadSQLiteSubprocess() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("tatwo-codex-main-thread-guard-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let db = root.appendingPathComponent("state_5.sqlite")
    let global = root.appendingPathComponent(".codex-global-state.json")
    FileManager.default.createFile(atPath: db.path, contents: Data())
    try "{}".data(using: .utf8)!.write(to: global)

    let bridge = TatwoCodexAppStateBridge(
      sourcePaths: .init(stateDatabaseURL: db, globalStateURL: global),
      maxThreadRows: 1,
      maxThreadsPerProject: 1,
      maxStandaloneThreads: 1)

    #expect(throws: TatwoCodexAppStateBridge.BridgeError.mainThreadSubprocessDenied) {
      try bridge.loadDocumentOverlay()
    }
  }

  @Test("merge preserves local thread data and appends mirrored Codex threads")
  func mergePreservesLocalThreadData() throws {
    let existingID = UUID(uuidString: "019f0000-0000-7000-8000-000000000001")!
    let local = TatwoNativeChatStoreDocument(
      threads: [TatwoNativeChatThread(id: existingID, title: "Local title", codexSessionID: "019f0000-0000-7000-8000-000000000001", lastPreview: "local preview")],
      projects: []
    )
    let overlay = TatwoNativeChatStoreDocument(
      threads: [
        TatwoNativeChatThread(id: existingID, title: "Codex title", codexSessionID: "019f0000-0000-7000-8000-000000000001", lastPreview: "remote preview"),
        TatwoNativeChatThread(id: UUID(uuidString: "019f0000-0000-7000-8000-000000000004")!, title: "New Codex", codexSessionID: "019f0000-0000-7000-8000-000000000004", lastPreview: "new")
      ],
      projects: []
    )

    let merged = TatwoCodexAppStateBridge.merge(base: local, overlay: overlay)
    #expect(merged.threads.count == 2)
    #expect(merged.threads.contains { $0.title == "Local title" && $0.lastPreview == "local preview" })
    #expect(merged.threads.contains { $0.title == "New Codex" })
  }

  @Test("merge does not auto-create projects from overlay Codex sessions")
  func mergeDoesNotAppendOverlayOnlyProjects() throws {
    let localThreadID = UUID(uuidString: "019f0000-0000-7000-8000-000000000031")!
    let overlayProjectThreadID = UUID(uuidString: "019f0000-0000-7000-8000-000000000032")!
    let local = TatwoNativeChatStoreDocument(
      threads: [
        TatwoNativeChatThread(
          id: localThreadID,
          title: "Local standalone",
          lastPreview: "keep")
      ],
      projects: [])
    let overlay = TatwoNativeChatStoreDocument(
      threads: [],
      projects: [
        TatwoNativeChatProject(
          name: "example",
          workdir: "/Users/example",
          threads: [
            TatwoNativeChatThread(
              id: overlayProjectThreadID,
              title: "MacBook home session",
              codexSessionID: overlayProjectThreadID.uuidString.lowercased(),
              lastPreview: "must not persist as a Tatwo project")
          ])
      ])

    let merged = TatwoCodexAppStateBridge.merge(base: local, overlay: overlay)
    #expect(merged.projects.isEmpty)
    #expect(merged.threads.map(\.id) == [localThreadID])
  }

  @Test("local overlay keeps Tatwo-created sessions until Codex mirror catches up")
  func localOverlayKeepsTatwoCreatedSessionMissingFromMirror() throws {
    let localThreadID = UUID(uuidString: "019f0000-0000-7000-8000-000000000021")!
    let providerSessionID = "019f0000-0000-7000-8000-000000000022"
    let mirroredThreadID = UUID(uuidString: "019f0000-0000-7000-8000-000000000023")!
    let staleMirrorID = "019f0000-0000-7000-8000-000000000024"

    let local = TatwoNativeChatStoreDocument(
      threads: [
        TatwoNativeChatThread(
          id: localThreadID,
          title: "Tatwo Fable5 session",
          codexSessionID: providerSessionID,
          codexCLISessionID: providerSessionID,
          lastPreview: "Fable5 already replied"),
        TatwoNativeChatThread(
          id: mirroredThreadID,
          title: "Already mirrored",
          codexSessionID: mirroredThreadID.uuidString.lowercased(),
          lastPreview: "Codex owns this row"),
        TatwoNativeChatThread(
          id: UUID(uuidString: staleMirrorID)!,
          title: "Stale mirror copy",
          codexSessionID: staleMirrorID,
          lastPreview: "must not be resurrected")
      ],
      projects: [])
    let mirror = TatwoNativeChatStoreDocument(
      threads: [
        TatwoNativeChatThread(
          id: mirroredThreadID,
          title: "Current Codex mirror",
          codexSessionID: mirroredThreadID.uuidString.lowercased(),
          lastPreview: "current")
      ],
      projects: [])

    let overlay = TatwoCodexAppStateBridge.localOverlayDocument(
      local: local,
      mirror: mirror)

    #expect(overlay.threads.map(\.id) == [localThreadID])
    #expect(overlay.threads.first?.codexSessionID == providerSessionID)
  }

  @Test("matching Codex mirror restores Tatwo plan goal and transcript state")
  func matchingCodexMirrorRestoresTatwoInteractionState() {
    let threadID = UUID(uuidString: "019f0000-0000-7000-8000-000000000031")!
    let localMessage = TatwoNativeChatStoredMessage(
      id: "019f0000-0000-7000-8000-000000000032",
      role: "assistant",
      text: "Tatwo saved reply")
    let local = TatwoNativeChatStoreDocument(
      projects: [
        TatwoNativeChatProject(
          name: "Tatwo",
          workdir: "/tmp/tatwo",
          threads: [
            TatwoNativeChatThread(
              id: threadID,
              title: "Local title",
              codexSessionID: threadID.uuidString.lowercased(),
              updatedAt: Date(timeIntervalSince1970: 300),
              isPlanModeEnabled: true,
              lastPreview: "local preview",
              workOSGoalID: "goal-local",
              workOSContractID: "contract-local",
              messages: [localMessage])
          ])
      ])
    let mirror = TatwoNativeChatStoreDocument(
      projects: [
        TatwoNativeChatProject(
          name: "Tatwo",
          workdir: "/tmp/tatwo",
          threads: [
            TatwoNativeChatThread(
              id: threadID,
              title: "Current Codex title",
              codexSessionID: threadID.uuidString.lowercased(),
              mirroredCodexWorkspacePath: "/tmp/tatwo/chat-workspace",
              sourceMarker: TatwoNativeChatThreadSourceMarker.codexAppMirror,
              updatedAt: Date(timeIntervalSince1970: 200),
              lastPreview: "current Codex preview")
          ])
      ])

    let restored = TatwoCodexAppStateBridge.restoringLocalInteractionState(
      local: local,
      in: mirror)
    let thread = restored.projects.first?.threads.first

    #expect(thread?.title == "Current Codex title")
    #expect(thread?.lastPreview == "current Codex preview")
    #expect(thread?.updatedAt == Date(timeIntervalSince1970: 300))
    #expect(thread?.isPlanModeEnabled == true)
    #expect(thread?.workOSGoalID == "goal-local")
    #expect(thread?.workOSContractID == "contract-local")
    #expect(thread?.messages == [localMessage])
    #expect(thread?.mirroredCodexWorkspacePath == "/tmp/tatwo/chat-workspace")
    #expect(
      thread?.sourceMarker
        == TatwoNativeChatThreadSourceMarker.codexAppMirror)
  }

  @Test("registerWorkspaceRoot updates Codex project roots with backup and no duplicates")
  func registerWorkspaceRootUpdatesCodexProjectRoots() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("tatwo-codex-bridge-sync-\(UUID().uuidString)", isDirectory: true)
    let projectRoot = root.appendingPathComponent("ProjectA", isDirectory: true)
    try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
    let db = root.appendingPathComponent("state_5.sqlite")
    let global = root.appendingPathComponent(".codex-global-state.json")

    let existingRoot = root.appendingPathComponent("Existing", isDirectory: true)
    try FileManager.default.createDirectory(at: existingRoot, withIntermediateDirectories: true)
    let originalJSON = """
      {
        "project-order": ["\(existingRoot.path)"],
        "electron-saved-workspace-roots": ["\(existingRoot.path)"],
        "projectless-thread-ids": ["thread-a"],
        "unknown-key-preserved": {"ok": true}
      }
      """
    try originalJSON.data(using: .utf8)!.write(to: global)

    let bridge = TatwoCodexAppStateBridge(
      sourcePaths: .init(stateDatabaseURL: db, globalStateURL: global),
      maxThreadRows: 1,
      maxThreadsPerProject: 1,
      maxStandaloneThreads: 1)

    let receipt = try bridge.registerWorkspaceRoot(projectRoot.path)
    #expect(receipt.didChange)
    #expect(receipt.changedKeys == ["project-order", "electron-saved-workspace-roots"])
    #expect(receipt.backupURL != nil)
    #expect(receipt.backupURL.map { FileManager.default.fileExists(atPath: $0.path) } == true)

    let object = try loadJSONObject(global)
    #expect((object["project-order"] as? [String])?.contains(projectRoot.path) == true)
    #expect((object["electron-saved-workspace-roots"] as? [String])?.contains(projectRoot.path) == true)
    #expect((object["projectless-thread-ids"] as? [String]) == ["thread-a"])
    #expect(((object["unknown-key-preserved"] as? [String: Any])?["ok"] as? Bool) == true)

    let secondReceipt = try bridge.registerWorkspaceRoot(projectRoot.path)
    #expect(!secondReceipt.didChange)
    let secondObject = try loadJSONObject(global)
    #expect((secondObject["project-order"] as? [String])?.filter { $0 == projectRoot.path }.count == 1)
    #expect((secondObject["electron-saved-workspace-roots"] as? [String])?.filter { $0 == projectRoot.path }.count == 1)
  }

  @Test("Codex mirror user ingestion strips App prompt contracts")
  func codexMirrorUserIngestionStripsAppPromptContracts() {
    let raw = """
      [Hidden TATWO Chat interface contract — do not quote to the user unless asked]
      private interface
      [/Hidden TATWO Chat interface contract]

      [Hidden TATWO Computer Host contract — do not quote]
      <TATWO_COMPUTER_ACTION>private host example</TATWO_COMPUTER_ACTION>
      [/Hidden TATWO Computer Host contract]

      [Hidden TATWO Work OS contract context]
      private contract
      [/Hidden TATWO Work OS contract context]

      [Hidden TATWO Ultrawork loopsConfig context]
      private loops
      [/Hidden TATWO Ultrawork loopsConfig context]

      Keep the imported user request.
      """

    #expect(
      TatwoCodexAppStateBridge.sanitizedTranscriptTextForMirrorTesting(
        raw,
        normalizedRole: "user")
        == "Keep the imported user request.")
  }

  @Test("Codex mirror user ingestion unwraps capped history and delegation")
  func codexMirrorUserIngestionUnwrapsTransportEnvelopes() {
    let capped = """
      Conversation history from this same Tatwo thread:
      bridgePolicy=capped-stateless; includedMessages=1; omittedMessages=0; maxCharacters=120000
      [assistant] old answer

      Current user request:
      [Hidden Codex-style Goal state]
      private goal
      [/Hidden Codex-style Goal state]

      Keep the current request.
      """
    #expect(
      TatwoCodexAppStateBridge.sanitizedTranscriptTextForMirrorTesting(
        capped,
        normalizedRole: "user")
        == "Keep the current request.")

    let delegated = """
      <codex_delegation>
        <source_thread_id>019fb652-a553-7890-b177-b939073e4f0d</source_thread_id>
        <input>Keep the delegated request.</input>
      </codex_delegation>
      """
    #expect(
      TatwoCodexAppStateBridge.sanitizedTranscriptTextForMirrorTesting(
        delegated,
        normalizedRole: "user")
        == "Keep the delegated request.")
  }

  @Test("Codex mirror drops a purely internal user prompt row")
  func codexMirrorDropsPureInternalUserPrompt() {
    let raw = """
      [Hidden TATWO Chat interface contract]
      private interface
      [/Hidden TATWO Chat interface contract]
      """
    #expect(
      TatwoCodexAppStateBridge.sanitizedTranscriptTextForMirrorTesting(
        raw,
        normalizedRole: "user") == nil)
  }

  private func runSQLite(db: URL, sql: String) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
    process.arguments = [db.path, sql]
    let error = Pipe()
    process.standardError = error
    try process.run()
    process.waitUntilExit()
    if process.terminationStatus != 0 {
      let message = String(data: error.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "sqlite3 failed"
      throw NSError(domain: "CodexAppStateBridgeTests", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: message])
    }
  }

  private func loadJSONObject(_ url: URL) throws -> [String: Any] {
    let data = try Data(contentsOf: url)
    let object = try JSONSerialization.jsonObject(with: data)
    guard let dictionary = object as? [String: Any] else {
      throw NSError(domain: "CodexAppStateBridgeTests", code: 2)
    }
    return dictionary
  }
}
