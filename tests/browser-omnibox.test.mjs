import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, mkdirSync } from 'node:fs';
import path from 'node:path';
import { runOmniboxNativeChecks } from './helpers/omnibox-native-checks.mjs';
import { browserVisualTokens, writeBrowserVisualTokens } from './helpers/browser-visual-fixture.mjs';
import { testScratch } from './helpers/test-scratch.mjs';

const read = name => readFileSync(new URL(`../App/Sources/Tatwo2/${name}`, import.meta.url), 'utf8');
const toolbar = read('Browser/EmbeddedBrowserToolbar.swift').split('struct EmbeddedBrowserToolbar: View')[1];
const metrics = read('Browser/BrowserOmniboxMetrics.swift');
const policy = read('Browser/BrowserOmniboxInteraction.swift');
const glass = read('Browser/BrowserOmniboxGlass.swift');
const tokens = read('Visual/LiquidGlassTokens.swift');
const workspace = read('Browser/BrowserWorkSpaceDesignView.swift');
const content = workspace.split('private var browserContent: some View {')[1].split('private func performBrowserAction')[0];
const value = name => Number(metrics.match(new RegExp(`static let ${name}: CGFloat = ([\\d.]+)`))?.[1]);

test('W67 collapsed and expanded geometry is tokenized and no longer pushes the page down', () => {
  assert.equal(value('collapsedHeight'), 24);
  assert.ok(value('collapsedHeight') < value('expandedFieldHeight'));
  assert.ok(value('expandedFieldHeight') < value('panelMinimumHeight'));
  assert.ok(value('panelMaximumWidth') <= 560);
  for (const key of ['collapsedHeight', 'expandedFieldHeight', 'panelMinimumHeight', 'panelMaximumWidth']) {
    assert.ok(toolbar.includes(`BrowserOmniboxMetrics.${key}`));
  }
  assert.match(content, /BrowserWorkSpaceCEFSurface[\s\S]*?\.overlay\(alignment: \.top\)/);
  assert.match(toolbar, /\.overlay\(alignment: \.top\) \{\s*if isExpanded \{/);
  assert.match(toolbar, /CGFloat\(choices.count\) \* BrowserOmniboxMetrics.suggestionRowHeight/);
  assert.match(toolbar, /panelMinimumHeight\)\s*\.fixedSize\(horizontal: false, vertical: true\)/);
  for (const source of [toolbar, content, glass]) {
    assert.doesNotMatch(source, /\.(?:padding|opacity|offset)\((?:\.\w+,\s*|y:\s*)?\d/);
    assert.doesNotMatch(source, /(?:height:|width:|cornerRadius:|size:)\s*\d/);
    assert.doesNotMatch(source, /Color\(red:/);
  }
});

test('W67 both appearances use Dashboard glass and semantic readable foregrounds', () => {
  for (const key of ['browserOmniboxLightTint', 'browserOmniboxDarkTint', 'browserOmniboxMaterial',
    'browserOmniboxTintOpacity', 'browserOmniboxInk', 'browserOmniboxMutedInk']) {
    assert.ok(tokens.includes(key));
  }
  assert.match(tokens, /browserOmniboxMaterial: Material = \.ultraThinMaterial/);
  assert.match(tokens, /case \.dark: browserOmniboxDarkTint\s*default: browserOmniboxLightTint/);
  assert.match(tokens, /browserOmniboxTintOpacity: Double \{ tintOpacity \}/);
  assert.match(tokens, /browserOmniboxInk = Color.primary/);
  assert.match(tokens, /browserOmniboxMutedInk = Color.secondary/);
  assert.match(glass, /@Environment\(\\\.colorScheme\)/);
  assert.match(glass, /fill\(LiquidGlassTokens.browserOmniboxMaterial\)/);
  assert.match(glass, /browserOmniboxTint\(for: colorScheme\)/);
  assert.doesNotMatch(toolbar + glass, /environment\(\\\.colorScheme, \.light\)|browserFieldFill|tatwoMatteSurface/);
});

test('W67 click opens; escape, focus loss and outside native clicks collapse without eating the destination event', () => {
  assert.match(toolbar, /Button\(action: expandEditor\)/);
  assert.match(toolbar, /private func expandEditor[\s\S]*?isExpanded\(after: \.click\)/);
  assert.match(policy, /case \.click, \.focusRequested: true/);
  assert.match(policy, /case \.escape, \.focusLost, \.submit: false/);
  assert.match(toolbar, /\.onExitCommand \{\s*addressText = state.urlString \?\? ""\s*dismissEditor\(\.escape\)/);
  assert.match(toolbar, /onChange\(of: addressFieldFocused.wrappedValue\)[\s\S]*?dismissEditor\(\.focusLost\)/);
  assert.match(toolbar, /BrowserOmniboxDismissMonitor \{ dismissEditor\(\.focusLost\) \}/);
  assert.match(policy, /addLocalMonitorForEvents/);
  assert.match(policy, /bounds.contains/);
  assert.match(policy, /return event/);
  assert.match(policy, /didResignKeyNotification/);
  assert.match(policy, /dismantleNSView[\s\S]*?view.stop\(\)/);
  assert.match(policy, /NSEvent.removeMonitor/);
  assert.doesNotMatch(policy, /addGlobalMonitor/);
  assert.doesNotMatch(toolbar, /\.onHover/);
});

test('W67 collapse shows committed host only and never presents HTTP as locked', () => {
  const trigger = toolbar.split('Button(action: expandEditor)')[1].split('.overlay(alignment: .top)')[0];
  assert.match(trigger, /Text\(BrowserOmniboxPresentation.domain\(for: state.urlString\)\)/);
  assert.doesNotMatch(trigger, /TextField|Text\(addressText\)|Text\(state.urlString/);
  assert.match(policy, /url.host/);
  assert.match(policy, /== "https" \? "lock.fill" : "globe"/);
});

test('W67 preserves identifier, dynamic binding notifications, open-tab callbacks and reduced motion', () => {
  assert.match(toolbar, /accessibilityLabel\("網址"\).accessibilityIdentifier\("browser.omnibox"\)/);
  assert.match(toolbar, /map.combos\(for: \.focusAddressBar\).first\?\.display/);
  assert.match(toolbar, /addressShortcutHint.map \{[^}]+編輯 · Esc 還原[^}]+\} \?\? "Esc 還原"/);
  assert.match(toolbar, /publisher\(for: BrowserShortcutMap.changed\)/);
  assert.match(toolbar, /onChange\(of: expansionRequest.wrappedValue, initial: true\)/);
  for (const parent of [workspace, read('Browser/EmbeddedBrowserView.swift')]) {
    assert.match(parent, /case \.focusAddressBar: addressExpansionRequested = true/);
    assert.match(parent, /expansionRequest: \$addressExpansionRequested/);
  }
  assert.doesNotMatch(toolbar, /Text\("⌘L|keyboardShortcut/);
  assert.match(toolbar, /openTabs.filter/);
  assert.match(toolbar, /onSelectTab\(id\)/);
  assert.match(toolbar, /@Environment\(\\\.accessibilityReduceMotion\)/);
  assert.match(toolbar, /animation\(reduceMotion \? nil/);
  assert.match(toolbar, /transition\(reduceMotion \? \.identity/);
  assert.match(content, /Menu \{[\s\S]*?accessibilityLabel\("瀏覽器功能"\)/);
  assert.match(content, /Button\("註解"\)[\s\S]*?\.fixedSize\(\)/);
  assert.match(read('Browser/EmbeddedBrowserView.swift'), /\.zIndex\(BrowserOmniboxMetrics.chromeZIndex\)\s*BrowserNavigationProgress/);
});

test('W67 fixture glass opt-in leaves unrelated W54 fixtures byte-identical', () => {
  const root = testScratch('w67-glass-fixture-');
  const ordinary = readFileSync(writeBrowserVisualTokens(root), 'utf8');
  assert.equal(ordinary, `import SwiftUI\nextension LiquidGlassTokens {\n${browserVisualTokens}\n}\n`);
  assert.doesNotMatch(ordinary, /static let tintOpacity|browserOmniboxMaterial/);
  const optedIn = path.join(root, 'omnibox');
  mkdirSync(optedIn);
  const withGlass = readFileSync(writeBrowserVisualTokens(optedIn, { includeOmnibox: true }), 'utf8');
  assert.match(withGlass, /browserOmniboxMaterial/);
  assert.equal([...withGlass.matchAll(/static let tintOpacity:/g)].length, 1);
});

test('W67 native click, typing, Esc, focus, tab suggestion and light/dark narrow layout', {
  skip: process.env.TATWO_W67_NATIVE !== '1' ? 'Requires lead compiler/UI approval (TATWO_W67_NATIVE=1)' : false,
  timeout: 180_000,
}, runOmniboxNativeChecks);
