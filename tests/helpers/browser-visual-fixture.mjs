import { readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';

// Extract production constants rather than duplicating v10 values in Swift stubs.
const source = readFileSync(new URL('../../App/Sources/Tatwo2/Visual/LiquidGlassTokens.swift', import.meta.url), 'utf8');
export const browserVisualTokens = source.split('// W54_V10_TOKENS_BEGIN')[1].split('// W54_V10_TOKENS_END')[0];
export const omniboxVisualTokens = source.split('// W67_OMNIBOX_TOKENS_BEGIN')[1].split('// W67_OMNIBOX_TOKENS_END')[0]
  + ['tint', 'tintOpacity', 'strokeOpacity'].map(name => {
    const declaration = source.match(new RegExp(`    static let ${name}: [^\\n]+`));
    if (!declaration) throw new Error(`Missing glass dependency: ${name}`);
    return declaration[0];
  }).join('\n');

export function writeBrowserVisualTokens(directory, { includeOmnibox = false } = {}) {
  const file = join(directory, 'BrowserVisualTokens.swift');
  const additional = includeOmnibox ? `\n${omniboxVisualTokens}` : '';
  writeFileSync(file, `import SwiftUI\nextension LiquidGlassTokens {\n${browserVisualTokens}${additional}\n}\n`);
  return file;
}

// Keep older geometry contracts meaningful after mechanical token extraction.
// The W54 tests separately assert that production views use the named tokens.
export function expandBrowserMetrics(text) {
  const metrics = readFileSync(new URL('../../App/Sources/Tatwo2/Visual/WorkspaceSidebarMetrics.swift', import.meta.url), 'utf8');
  const values = new Map([...metrics.matchAll(/static let (\w+): (?:CGFloat|Double|TimeInterval) = (-?\d+(?:\.\d+)?)\b/g)]
    .map(([, name, value]) => [name, value]));
  return text.replace(/BrowserSidebarMetrics\.(\w+)/g, (reference, name) => values.get(name) ?? reference);
}
