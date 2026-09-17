import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { execFileSync, spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { testScratch } from './helpers/test-scratch.mjs';

const read = p => fs.readFileSync(new URL('../App/Sources/Tatwo2/' + p, import.meta.url), 'utf8');

test('W89 production Swift: empty workspace precondition picks owner, bot gate, project gate', {
  timeout: 120000, skip: process.platform !== 'darwin' ? 'macOS toolchain required' : false,
}, () => {
  const root = testScratch('w89-precondition-');
  // 生產檔原樣編譯（不抄一份），只補一個 @main 跑判斷。
  const production = read('Space/SpaceCreation.swift');
  const checks = `
@main struct Checks {
    static func require(_ ok: Bool, _ label: String) {
        if !ok { fatalError(label) }
        print("PASS " + label)
    }
    static func main() {
        require(SpaceCreation.outcome(botIDs: [], selectedBotID: nil, projectWorkdir: nil) == .needsProject,
                "no bot and no project needs project")
        require(SpaceCreation.outcome(botIDs: [], selectedBotID: nil, projectWorkdir: "   ") == .needsProject,
                "blank project workdir needs project")
        require(SpaceCreation.outcome(botIDs: [], selectedBotID: nil, projectWorkdir: "/synthetic/w89") == .needsBot,
                "needs_bot when owner has no bot")
        require(SpaceCreation.outcome(botIDs: ["bot-a", "bot-b"], selectedBotID: nil, projectWorkdir: nil)
                == .ready(ownerBotID: "bot-a"), "no selection falls back to first library bot")
        require(SpaceCreation.outcome(botIDs: ["bot-a", "bot-b"], selectedBotID: "bot-b", projectWorkdir: nil)
                == .ready(ownerBotID: "bot-b"), "selected bot becomes owner")
        require(SpaceCreation.outcome(botIDs: ["bot-a"], selectedBotID: "bot-missing", projectWorkdir: nil)
                == .ready(ownerBotID: "bot-a"), "stale selection falls back to first library bot")
        require(SpaceCreation.defaultDensity == "compact", "default density is compact")
        require(SpaceCreation.normalizedName("  第一個領域  ") == "第一個領域", "name trimmed")
        require(SpaceCreation.normalizedName("   ") == nil, "blank name rejected")
        require(SpaceCreation.nameFromPath("/synthetic/w89/open design") == "open design", "name from last path component")
        require(SpaceCreation.nameFromPath("  ") == nil, "blank path has no name")
        require(SpaceCreation.actionTitle(for: .ready(ownerBotID: "bot-a")) == "建立第一個領域", "create title")
        require(SpaceCreation.actionTitle(for: .needsBot) == "先建立 bot", "needs bot title")
        require(SpaceCreation.actionTitle(for: .needsProject) == "先選擇專案", "needs project title")
        require(SpaceCreation.successText(name: "第一個領域") == "已建立領域 第一個領域", "success text")
        print("W89PRECONDITION SUMMARY failures=0")
    }
}
`;
  const source = path.join(root, 'fixture.swift');
  fs.writeFileSync(source, production + checks);
  const build = spawnSync('swiftc', ['-parse-as-library', source, '-o', path.join(root, 'fixture')],
    { encoding: 'utf8', timeout: 110000 });
  assert.equal(build.status, 0, build.stderr);
  const output = execFileSync(path.join(root, 'fixture'), [], { encoding: 'utf8', timeout: 30000 });
  assert.match(output, /W89PRECONDITION SUMMARY failures=0/);
  assert.ok(output.includes('PASS needs_bot when owner has no bot'), 'needs_bot case must run');
});

test('W89 settings › Space empty state is not an error and owns the only creation path', () => {
  const controller = read('Space/SpaceWorkspaceController.swift');
  // 0 個 space 不再寫 error。
  assert.doesNotMatch(controller, /尚無領域 Space/);
  assert.match(controller, /guard !domains\.isEmpty else \{ isEmptyWorkspace = true; return \}/);
  const create = controller.slice(controller.indexOf('    func createDomain('),
                                  controller.indexOf('    /// 空狀態導引'));
  assert.match(create, /SpaceCreation\.normalizedName\(rawName\)/);
  assert.match(create, /guard case \.ready\(let owner\) = outcome else \{ return \.blocked\(outcome\) \}/);
  assert.match(create, /createSpace\(name: name, density: density \?\? SpaceCreation\.defaultDensity, ownerBotID: owner\)/);
  assert.match(create, /await load\(library: library\)/);
  assert.match(create, /selectDomain\(space\.id\)/);

  const view = read('Space/SpaceLiveSetupView.swift');
  const empty = view.slice(view.indexOf('struct SpaceEmptyDomainView'), view.indexOf('struct SpaceLiveConversationView'));
  // 空狀態不再顯示「Work Space 資料未就緒」；讀取中仍然顯示讀取文案。
  assert.doesNotMatch(empty, /Work Space 資料未就緒/);
  assert.match(view, /controller\.error == nil \? SpaceCreation\.loadingText : "Work Space 資料未就緒"/);
  assert.match(view, /\} else if controller\.isEmptyWorkspace \{\n\s*SpaceEmptyDomainView\(\)/);
  assert.match(empty, /Text\(SpaceCreation\.emptyExplanation\)/);
  assert.match(empty, /Button\(SpaceCreation\.createTitle, action: create\)/);
  assert.match(empty, /\.onSubmit\(create\)/);
  assert.match(empty, /Button\(SpaceCreation\.needsBotTitle\) \{ controller\.openBotPage\(\) \}/);
  // 沒有目前專案只給提示文字，不做導引。
  const needsProject = empty.slice(empty.indexOf('case .needsProject:'), empty.indexOf('if let failure'));
  assert.doesNotMatch(needsProject, /Button\(/);
  assert.match(needsProject, /SpaceCreation\.needsProjectTitle/);
});

test('W89 Bot page 三段流 live 走同一條建立函式；fixture 維持展示文案', () => {
  const state = read('Bot/BotPageState.swift');
  const complete = state.slice(state.indexOf('    func addSpaceComplete('), state.indexOf('    /// 取消/Esc'));
  assert.match(complete, /guard usesLiveBots else \{ return \}/);
  assert.match(complete, /SpaceWorkspaceController\.shared\.createDomain\(name: rawName, ownerBotID: owner, density: density\)/);
  assert.match(complete, /case \.created\(_, let created\): addSpaceCreatedName = created/);
  assert.match(complete, /case \.failed\(let message\): addSpaceFailure = message/);

  const page = read('Bot/BotPage.swift');
  const completion = page.slice(page.indexOf('            case .completionMock:'),
                                page.indexOf('        .frame(maxWidth: .infinity, maxHeight: .infinity)\n        .padding(24)\n    }\n\n    // MARK: - 右緣書側標籤'));
  assert.match(completion, /state\.addSpaceCreatedName\.map\(SpaceCreation\.successText\(name:\)\)/);
  assert.match(completion, /\?\? "已交由 agent 搭建（展示）"/);
  assert.match(completion, /state\.addSpaceFailure/);
  assert.match(page, /state\.addSpaceComplete\(name: SpaceCreation\.nameFromPath\(addSpacePath\) \?\? addSpacePath,\s*density: state\.addSpaceDensity\?\.rawValue\)/);
});

test('W89 dead code removed: BotStore fixtureSeed/systemPrompt gone, live library reused', () => {
  const store = read('Facade/BotStore.swift');
  assert.doesNotMatch(store, /fixtureSeed/);
  assert.doesNotMatch(store, /static func systemPrompt/);
  assert.match(store, /init\(library: BotLibrary\)/);
  // createSpace 本體不動。
  assert.match(store, /func createSpace\(name: String, density: String, ownerBotID: String\) async throws -> BotSpaceRecord/);
  const sources = fileURLToPath(new URL('../App/Sources', import.meta.url));
  const survivors = spawnSync('grep', ['-rl', 'fixtureSeed', sources], { encoding: 'utf8' });
  assert.equal(survivors.stdout.trim(), '', 'no caller may reference the removed seed');
});

test('W89 production binary: from zero to one domain writes exactly one bot-spaces record', {
  timeout: 180000,
  skip: process.env.TATWO2_TEST_BINARY ? false : 'TATWO2_TEST_BINARY required (built Tatwo2 debug binary)',
}, () => {
  const root = testScratch('w89-from-zero-');
  const home = path.join(root, 'isolated-process-home');
  fs.mkdirSync(home);
  const output = execFileSync(process.env.TATWO2_TEST_BINARY, [], {
    encoding: 'utf8', timeout: 150000,
    env: { PATH: process.env.PATH, TMPDIR: process.env.TMPDIR, HOME: home, CFFIXED_USER_HOME: home,
      TATWO2_W89_TEST_ROOT: root, TATWO2_LIVE_ROOT: path.join(root, 'live') },
  });
  for (const label of ['empty-library-is-not-error', 'empty-library-state-empty', 'no-bot-blocks-creation',
    'no-bot-returns-needs-bot-or-project', 'no-bot-still-needs-bot', 'bot-owner-ready',
    'created-trimmed-name', 'controller-one-domain', 'bot-spaces-json-single-record',
    'owner-bot-links-space', 'blank-name-rejected']) {
    assert.ok(output.includes('W89TEST PASS ' + label), label + '\n' + output);
  }
  assert.match(output, /W89TEST SUMMARY failures=0/);
  const spaces = JSON.parse(fs.readFileSync(path.join(root, 'live', 'bot-spaces.json'), 'utf8'));
  assert.equal(spaces.length, 1);
  assert.equal(spaces[0].name, '第一個領域');
  assert.equal(spaces[0].density, 'compact');
});
