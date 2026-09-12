import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import test from 'node:test';
import { fileURLToPath } from 'node:url';
import { createHash } from 'node:crypto';

const repo = fileURLToPath(new URL('..', import.meta.url));
test('production attachment tiles render previews without overflowing adjacent files', { timeout: 120_000 }, t => {
  if (process.platform !== 'darwin') return t.skip('requires AppKit');
  const leaf = fs.readFileSync(path.join(repo, 'App/Sources/Tatwo2/Chat/ChatPageLeafViews.swift'), 'utf8');
  const derived = fs.readFileSync(path.join(repo, 'App/Sources/Tatwo2/Chat/ChatPageLeafViews+MessageDerived.swift'), 'utf8');
  const composer = fs.readFileSync(path.join(repo, 'App/Sources/Tatwo2/Chat/ChatPage+Composer.swift'), 'utf8');
  const helperPaths = ['ChatAttachmentPreviewSurface.swift', 'ChatAttachmentImageLoader.swift', 'ChatAttachmentImageViews.swift'];
  const helpers = helperPaths.map(name => fs.readFileSync(path.join(repo, 'App/Sources/Tatwo2/Chat', name), 'utf8')).join('\n');
  assert.match(composer, /ChatLoadedImageAttachment\(/);
  assert.doesNotMatch(composer, /NSImage\(contentsOfFile:/);
  assert.match(helpers, /\.sheet\(isPresented: \$isPreviewPresented\)/);
  assert.match(helpers, /ChatImagePreviewSurface\(/);
  const start = leaf.indexOf('private struct ChatAttachmentStrip');
  const end = leaf.indexOf('private struct ChatAssistantTranscriptParseTaskID');
  const attachmentStart = derived.indexOf('struct ChatInlineAttachment');
  const attachmentEnd = derived.indexOf('struct ChatModelAvatar');
  const composerStart = composer.indexOf('    @ViewBuilder\n    func droppedAttachmentChip');
  const composerEnd = composer.indexOf('    /// 停止鈕', composerStart);
  assert.ok(start >= 0 && end > start && attachmentStart >= 0 && attachmentEnd > attachmentStart);
  assert.ok(composerStart >= 0 && composerEnd > composerStart);
  const scratch = fs.mkdtempSync(path.join(repo, 'output/lightweight-repair/attachment-render.'));
  const source = `
import SwiftUI
import AppKit
import Foundation
import QuickLook
import ImageIO
enum ChatTypography { static let transcriptMeta = Font.system(size: 12) }
enum TatwoImageAssetStore {
    static func isImageCandidatePath(_ path: String) -> Bool {
        ["png","jpg","jpeg","gif","webp"].contains(URL(fileURLWithPath: path).pathExtension.lowercased())
    }
}
${derived.slice(attachmentStart, attachmentEnd)}
${helpers}
enum LiquidGlassTokens { static let brandAccent = Color.blue }
struct ComposerAttachmentModel {
    var droppedPaths: [String]
    var droppedPathDisplayNames: [String: String] = [:]
    func removeDroppedPath(_ path: String) {}
}
struct ComposerAttachmentFixture: View {
    let model: ComposerAttachmentModel
    var body: some View {
        HStack { ForEach(model.droppedPaths, id: \\.self) { droppedAttachmentChip($0) } }
    }
${composer.slice(composerStart, composerEnd)}
}
${leaf.slice(start, end)}
${fs.readFileSync(path.join(repo, 'tests/fixtures/attachment-render-checks.swift'), 'utf8')}
`;
  fs.writeFileSync(path.join(scratch, 'checks.swift'), source);
  const build = spawnSync('/bin/bash', ['-c', `
set -euo pipefail
receipt=$(bash scripts/tatwo-build-lock.sh acquire --timeout 0 --pid $$)
token=$(printf '%s\\n' "$receipt" | sed -n 's/^token=//p')
trap 'bash scripts/tatwo-build-lock.sh release --token "$token" >/dev/null' EXIT
nice -n 10 xcrun swiftc -num-threads 2 "$1" -o "$2"
`, 'attachment-render', path.join(scratch, 'checks.swift'), path.join(scratch, 'checks')], {
    cwd: repo, encoding: 'utf8', timeout: 100_000, env: { ...process.env, TMPDIR: scratch },
  });
  fs.writeFileSync(path.join(scratch, 'build.log'), build.stdout + build.stderr);
  assert.equal(build.status, 0, build.stderr || String(build.error));
  const run = spawnSync(path.join(scratch, 'checks'), [scratch], {
    encoding: 'utf8', timeout: 15_000, env: { HOME: scratch, TMPDIR: scratch, PATH: '/usr/bin:/bin' },
  });
  process.stdout.write(run.stdout);
  fs.writeFileSync(path.join(scratch, 'run.log'), run.stdout + run.stderr);
  fs.writeFileSync(path.join(scratch, 'metadata.json'), JSON.stringify({
    runID: path.basename(scratch), timestamp: new Date().toISOString(),
    surface: 'production attachment strip, live loader and expanded preview (isolated fixture)',
    viewport: { width: 370, height: 250 },
    sourceSHA256: createHash('sha256').update(source).digest('hex'),
    screenshots: Object.fromEntries([
      'attachments.png', 'composer.png', 'clicked-preview.png', 'clicked-next-missing.png',
      'clicked-previous.png', 'live-expanded.png',
    ].filter(name => fs.existsSync(path.join(scratch, name))).map(name => {
      const png = fs.readFileSync(path.join(scratch, name));
      return [name, { sha256: createHash('sha256').update(png).digest('hex'),
        pixelWidth: png.readUInt32BE(16), pixelHeight: png.readUInt32BE(20) }];
    })),
    fullAppAcceptance: false,
  }, null, 2));
  process.stdout.write(`ATTACHMENT_RENDER_DIRECTORY ${scratch}\n`);
  assert.equal(run.status, 0, run.stdout + run.stderr);
});
