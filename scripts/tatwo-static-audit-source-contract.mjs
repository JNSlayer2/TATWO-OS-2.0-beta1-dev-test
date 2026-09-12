import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";

const GLOB_TOKEN = /[*?[\]{}]/;

export function readRequiredSources({ root, manifest }) {
  if (typeof root !== "string" || root.length === 0) {
    throw new TypeError("required source root must be a non-empty string");
  }
  if (!Array.isArray(manifest) || manifest.length === 0) {
    throw new TypeError("required source manifest must be a non-empty array");
  }

  const resolvedRoot = path.resolve(root);
  const sources = new Map();
  const files = [];
  const seenPaths = new Set();
  let canonicalRoot;

  for (const entry of manifest) {
    const id = entry?.id;
    const relativePath = entry?.relativePath;
    if (typeof id !== "string" || id.length === 0) {
      throw new TypeError("required source id must be a non-empty string");
    }
    if (sources.has(id)) {
      throw new Error(`duplicate required source id: ${id}`);
    }
    assertExplicitRelativePath(relativePath);
    if (seenPaths.has(relativePath)) {
      throw new Error(`duplicate required source path: ${relativePath}`);
    }

    const absolutePath = path.resolve(resolvedRoot, relativePath);
    if (!isWithinRoot(resolvedRoot, absolutePath)) {
      throw new Error(`required source escapes root: ${relativePath}`);
    }

    let stat;
    let canonicalPath;
    try {
      canonicalRoot ??= fs.realpathSync(resolvedRoot);
      let componentPath = resolvedRoot;
      for (const component of path.relative(resolvedRoot, absolutePath).split(path.sep)) {
        componentPath = path.join(componentPath, component);
        stat = fs.lstatSync(componentPath);
        if (stat.isSymbolicLink()) {
          throw new Error(`required source path contains symlink: ${relativePath}`);
        }
      }
      canonicalPath = fs.realpathSync(absolutePath);
    } catch (error) {
      if (error?.code === "ENOENT") {
        throw new Error(`missing required source: ${relativePath}`);
      }
      throw error;
    }
    if (!isWithinRoot(canonicalRoot, canonicalPath)) {
      throw new Error(`required source escapes root: ${relativePath}`);
    }
    if (!stat.isFile()) {
      throw new Error(`required source is not a regular file: ${relativePath}`);
    }

    const bytes = fs.readFileSync(canonicalPath);
    const text = bytes.toString("utf8");
    if (text.trim().length === 0) {
      throw new Error(`empty required source: ${relativePath}`);
    }

    sources.set(id, { id, path: relativePath, absolutePath, text });
    files.push({
      id,
      path: relativePath,
      bytes: bytes.length,
      sha256: crypto.createHash("sha256").update(bytes).digest("hex"),
    });
    seenPaths.add(relativePath);
  }

  return {
    sources,
    sourceSnapshot: {
      algorithm: "sha256",
      files,
    },
  };
}

function isWithinRoot(root, candidate) {
  return candidate === root || candidate.startsWith(`${root}${path.sep}`);
}

export function extractSwiftTypeBody(source, {
  kind,
  name,
  stripComments = true,
}) {
  if (kind !== "struct" && kind !== "enum") {
    throw new TypeError(`unsupported Swift symbol kind: ${kind}`);
  }
  if (typeof name !== "string" || !/^[A-Za-z_][A-Za-z0-9_]*$/.test(name)) {
    throw new TypeError("Swift symbol name must be an identifier");
  }
  if (typeof source !== "string" || source.trim().length === 0) {
    throw new Error(`empty Swift source while extracting ${kind} ${name}`);
  }

  const { commentsStripped, codeMask } = scanSwiftSource(source);
  const declaration = new RegExp(
    `\\b${kind}\\s+${escapeRegExp(name)}\\b[^\\{;]*\\{`,
    "g",
  );
  const matches = [...codeMask.matchAll(declaration)];
  if (matches.length === 0) {
    throw new Error(`missing Swift ${kind} symbol: ${name}`);
  }
  if (matches.length !== 1) {
    throw new Error(`ambiguous Swift ${kind} symbol: ${name}`);
  }

  const match = matches[0];
  const openBrace = match.index + match[0].lastIndexOf("{");
  let depth = 0;
  for (let index = openBrace; index < codeMask.length; index += 1) {
    if (codeMask[index] === "{") depth += 1;
    if (codeMask[index] !== "}") continue;
    depth -= 1;
    if (depth === 0) {
      const selected = stripComments ? commentsStripped : source;
      return selected.slice(openBrace + 1, index);
    }
  }

  throw new Error(`incomplete braces for Swift ${kind} symbol: ${name}`);
}

export function extractSwiftFunctionBody(source, {
  name,
  stripComments = true,
}) {
  if (typeof name !== "string" || !/^[A-Za-z_][A-Za-z0-9_]*$/.test(name)) {
    throw new TypeError("Swift function name must be an identifier");
  }
  if (typeof source !== "string" || source.trim().length === 0) {
    throw new Error(`empty Swift source while extracting func ${name}`);
  }

  const { commentsStripped, codeMask } = scanSwiftSource(source);
  const declaration = new RegExp(
    `\\bfunc\\s+${escapeRegExp(name)}\\b[^\\{;]*\\{`,
    "g",
  );
  const matches = [...codeMask.matchAll(declaration)];
  if (matches.length === 0) {
    throw new Error(`missing Swift func symbol: ${name}`);
  }
  if (matches.length !== 1) {
    throw new Error(`ambiguous Swift func symbol: ${name}`);
  }

  const match = matches[0];
  const openBrace = match.index + match[0].lastIndexOf("{");
  let depth = 0;
  for (let index = openBrace; index < codeMask.length; index += 1) {
    if (codeMask[index] === "{") depth += 1;
    if (codeMask[index] !== "}") continue;
    depth -= 1;
    if (depth === 0) {
      const selected = stripComments ? commentsStripped : source;
      return selected.slice(openBrace + 1, index);
    }
  }

  throw new Error(`incomplete braces for Swift func symbol: ${name}`);
}

export function requireSourceMarker(source, marker, {
  sourcePath = "source",
  symbol = "scope",
} = {}) {
  if (typeof marker !== "string" || marker.length === 0) {
    throw new TypeError("required source marker must be a non-empty string");
  }
  if (typeof source !== "string") {
    throw new Error(`missing required marker in ${sourcePath} ${symbol}: ${marker}`);
  }
  const markerMask = scanSwiftSource(marker).codeMask;
  const codeOffsets = [...markerMask]
    .map((character, index) => ({ character, index }))
    .filter(({ character }) => !/\s/.test(character));
  if (codeOffsets.length === 0) {
    throw new TypeError("required source marker must contain Swift code");
  }

  const sourceMask = scanSwiftSource(source).codeMask;
  let start = source.indexOf(marker);
  while (start >= 0) {
    if (codeOffsets.every(({ character, index }) => sourceMask[start + index] === character)) {
      return;
    }
    start = source.indexOf(marker, start + 1);
  }
  throw new Error(`missing required marker in ${sourcePath} ${symbol}: ${marker}`);
}

function assertExplicitRelativePath(relativePath) {
  if (
    typeof relativePath !== "string"
    || relativePath.length === 0
    || path.isAbsolute(relativePath)
    || relativePath.includes("\0")
    || GLOB_TOKEN.test(relativePath)
  ) {
    throw new Error(`required source must use an explicit file path: ${relativePath}`);
  }
  const normalized = path.normalize(relativePath);
  if (normalized === "." || normalized === ".." || normalized.startsWith(`..${path.sep}`)) {
    throw new Error(`required source must use an explicit file path: ${relativePath}`);
  }
}

function scanSwiftSource(source) {
  const commentsStripped = [...source];
  const codeMask = [...source];
  let index = 0;
  let blockDepth = 0;

  while (index < source.length) {
    if (source.startsWith("//", index)) {
      index = maskLineComment(source, commentsStripped, codeMask, index);
      continue;
    }
    if (source.startsWith("/*", index)) {
      ({ index, blockDepth } = maskBlockComment(
        source,
        commentsStripped,
        codeMask,
        index,
        blockDepth,
      ));
      continue;
    }

    const stringStart = swiftStringStart(source, index);
    if (stringStart) {
      index = maskString(source, codeMask, index, stringStart);
      continue;
    }
    index += 1;
  }

  return {
    commentsStripped: commentsStripped.join(""),
    codeMask: codeMask.join(""),
  };
}

function maskLineComment(source, commentsStripped, codeMask, start) {
  let index = start;
  while (index < source.length && source[index] !== "\n") {
    commentsStripped[index] = " ";
    codeMask[index] = " ";
    index += 1;
  }
  return index;
}

function maskBlockComment(source, commentsStripped, codeMask, start, initialDepth) {
  let index = start;
  let blockDepth = initialDepth + 1;
  maskRange(source, commentsStripped, codeMask, index, index + 2);
  index += 2;

  while (index < source.length && blockDepth > 0) {
    if (source.startsWith("/*", index)) {
      blockDepth += 1;
      maskRange(source, commentsStripped, codeMask, index, index + 2);
      index += 2;
      continue;
    }
    if (source.startsWith("*/", index)) {
      blockDepth -= 1;
      maskRange(source, commentsStripped, codeMask, index, index + 2);
      index += 2;
      continue;
    }
    maskRange(source, commentsStripped, codeMask, index, index + 1);
    index += 1;
  }
  if (blockDepth !== 0) {
    throw new Error("incomplete Swift block comment");
  }
  return { index, blockDepth };
}

function maskString(source, codeMask, start, { hashes, multiline }) {
  const end = findSwiftStringEnd(source, start, { hashes, multiline });
  maskCodeRange(source, codeMask, start, end);
  return end;
}

function findSwiftStringEnd(source, start, { hashes, multiline }) {
  const openingLength = hashes + (multiline ? 3 : 1);
  const closing = `${multiline ? '"""' : '"'}${"#".repeat(hashes)}`;
  let index = start + openingLength;

  while (index < source.length) {
    const interpolationLength = swiftInterpolationLength(source, index, hashes);
    if (interpolationLength > 0) {
      index = findSwiftInterpolationEnd(source, index, interpolationLength);
      continue;
    }
    if (source.startsWith(closing, index) && !isEscapedQuote(source, index, hashes)) {
      return index + closing.length;
    }
    index += 1;
  }

  throw new Error("incomplete Swift string literal");
}

function findSwiftInterpolationEnd(source, start, openingLength) {
  let index = start + openingLength;
  let depth = 1;

  while (index < source.length) {
    if (source.startsWith("//", index)) {
      index = source.indexOf("\n", index + 2);
      if (index < 0) throw new Error("incomplete Swift string interpolation");
      continue;
    }
    if (source.startsWith("/*", index)) {
      index = findSwiftBlockCommentEnd(source, index);
      continue;
    }
    const stringStart = swiftStringStart(source, index);
    if (stringStart) {
      index = findSwiftStringEnd(source, index, stringStart);
      continue;
    }
    if (source[index] === "(") depth += 1;
    if (source[index] === ")") {
      depth -= 1;
      if (depth === 0) return index + 1;
    }
    index += 1;
  }

  throw new Error("incomplete Swift string interpolation");
}

function findSwiftBlockCommentEnd(source, start) {
  let index = start + 2;
  let depth = 1;
  while (index < source.length) {
    if (source.startsWith("/*", index)) {
      depth += 1;
      index += 2;
      continue;
    }
    if (source.startsWith("*/", index)) {
      depth -= 1;
      index += 2;
      if (depth === 0) return index;
      continue;
    }
    index += 1;
  }
  throw new Error("incomplete Swift block comment");
}

function swiftInterpolationLength(source, index, hashes) {
  const opening = `\\${"#".repeat(hashes)}(`;
  if (!source.startsWith(opening, index) || isEscapedBackslash(source, index)) {
    return 0;
  }
  return opening.length;
}

function isEscapedBackslash(source, index) {
  let slashCount = 0;
  for (let cursor = index - 1; cursor >= 0 && source[cursor] === "\\"; cursor -= 1) {
    slashCount += 1;
  }
  return slashCount % 2 === 1;
}

function swiftStringStart(source, index) {
  let cursor = index;
  while (source[cursor] === "#") cursor += 1;
  if (source[cursor] !== '"') return null;
  const hashes = cursor - index;
  return {
    hashes,
    multiline: source.startsWith('"""', cursor),
  };
}

function isEscapedQuote(source, quoteIndex, hashes) {
  if (hashes > 0) {
    return source.slice(Math.max(0, quoteIndex - hashes - 1), quoteIndex)
      === `\\${"#".repeat(hashes)}`;
  }
  let slashCount = 0;
  for (let index = quoteIndex - 1; index >= 0 && source[index] === "\\"; index -= 1) {
    slashCount += 1;
  }
  return slashCount % 2 === 1;
}

function maskRange(source, commentsStripped, codeMask, start, end) {
  for (let index = start; index < end; index += 1) {
    const replacement = source[index] === "\n" ? "\n" : " ";
    commentsStripped[index] = replacement;
    codeMask[index] = replacement;
  }
}

function maskCodeRange(source, codeMask, start, end) {
  for (let index = start; index < end; index += 1) {
    codeMask[index] = source[index] === "\n" ? "\n" : " ";
  }
}

function escapeRegExp(value) {
  return value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}
