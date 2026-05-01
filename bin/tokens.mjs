#!/usr/bin/env node
// Sure design tokens build.
// Reads design/tokens/sure.tokens.json (W3C DTCG-flavored), emits one Tailwind v4 CSS file.

import { readFileSync, writeFileSync } from "node:fs";
import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const TOKENS = resolve(ROOT, "design/tokens/sure.tokens.json");
const OUT = resolve(ROOT, "app/assets/tailwind/sure-design-system/_generated.css");

const HEADER = `/*
 * GENERATED — do not edit by hand.
 * Source: design/tokens/sure.tokens.json
 * Build:  npm run tokens:build
 */
`;

// Single inline keyframe; not worth its own JSON token.
const KEYFRAMES = `  @keyframes stroke-fill {
    0% { stroke-dashoffset: 43.9822971503; }
    100% { stroke-dashoffset: 0; }
  }`;

// Yield [path, node] for every token leaf (object with $value or $type === "utility").
function* walk(node, path = []) {
  if (!node || typeof node !== "object") return;
  if ("$value" in node || node.$type === "utility") {
    yield [path, node];
    if (!node.$value || typeof node.$value !== "object") return;
  }
  for (const [k, v] of Object.entries(node)) {
    if (k.startsWith("$")) continue;
    yield* walk(v, [...path, k]);
  }
}

// Path → CSS variable name. Trailing `DEFAULT` segment is dropped (Tailwind convention).
function varName(path) {
  const cleaned = path[path.length - 1] === "DEFAULT" ? path.slice(0, -1) : path;
  return "--" + cleaned.join("-");
}

// Set of valid token paths (e.g. "color.gray.50", "utility.border-tertiary").
// Populated once at the start of build(); referenced by resolveTemplate() and
// refToClass() so a typo'd `{ref}` fails the build instead of emitting broken
// CSS or a dangling utility class.
let VALID_PATHS = null;

function assertKnownRef(ref, source) {
  if (VALID_PATHS && !VALID_PATHS.has(ref)) {
    throw new Error(
      `[tokens] Unknown token reference \`${source}\` (resolved path: \`${ref}\`). ` +
      `Add it to design/tokens/sure.tokens.json or fix the typo.`
    );
  }
}

// Resolve template strings:
//   {a.b}     → var(--a-b)
//   {a.b|N%}  → --alpha(var(--a-b) / N%)
function resolveTemplate(s) {
  if (typeof s !== "string") return s;
  return s.replace(/\{([^|}]+)(?:\|([^}]+))?\}/g, (whole, ref, alpha) => {
    assertKnownRef(ref, whole);
    const cssVar = "--" + ref.split(".").join("-");
    return alpha ? `--alpha(var(${cssVar}) / ${alpha})` : `var(${cssVar})`;
  });
}

// {color.gray.50} or {utility.border-tertiary} → Tailwind utility class name with the given prefix.
// Drops a leading `color.` segment (since Tailwind colors are referenced as `bg-gray-50`, not `bg-color-gray-50`).
function refToClass(refStr, prefix) {
  const inner = refStr.replace(/^\{|\}$/g, "");
  assertKnownRef(inner, refStr);
  if (inner.startsWith("utility.")) return inner.slice("utility.".length);
  const parts = inner.split(".");
  if (parts[0] === "color") parts.shift();
  return prefix + "-" + parts.join("-");
}

// Utility @apply argument. If value is a raw class string (no `{}`), pass through.
// If value is a `{ref}`, resolve to a Tailwind class via the given prefix.
function utilityClasses(value, prefix) {
  if (typeof value !== "string") return "";
  if (!value.includes("{")) return value;
  return refToClass(value, prefix);
}

function build() {
  const tokens = JSON.parse(readFileSync(TOKENS, "utf8"));

  // Pre-compute the set of valid token paths so refs can be validated as we go.
  VALID_PATHS = new Set();
  for (const [path] of walk(tokens)) {
    VALID_PATHS.add(path.join("."));
  }

  const themeLines = [];
  const darkLines = [];
  const utilityBlocks = [];

  for (const [path, node] of walk(tokens)) {
    if (path[0] === "utility") {
      const name = path.slice(1).join("-");
      const ext = node.$extensions || {};

      if (ext["sure.compose"]) {
        utilityBlocks.push(`@utility ${name} {\n  @apply ${ext["sure.compose"].join(" ")};\n}`);
        continue;
      }

      const prefix = ext["sure.utility"]?.prefix;
      const raw = ext["sure.utility"]?.raw;
      const dark = ext["sure.dark"];

      const lightLine = raw
        ? `${raw}: ${resolveTemplate(node.$value)};`
        : `@apply ${utilityClasses(node.$value, prefix)};`;

      let block = `@utility ${name} {\n  ${lightLine}`;
      if (dark) {
        const darkLine = raw
          ? `${raw}: ${resolveTemplate(dark)};`
          : `@apply ${utilityClasses(dark, prefix)};`;
        block += `\n\n  @variant theme-dark {\n    ${darkLine}\n  }`;
      }
      block += `\n}`;
      utilityBlocks.push(block);
      continue;
    }

    const name = varName(path);
    themeLines.push(`  ${name}: ${resolveTemplate(node.$value)};`);

    const dark = node.$extensions?.["sure.dark"];
    if (dark !== undefined) {
      darkLines.push(`    ${name}: ${resolveTemplate(dark)};`);
    }
  }

  const css = `${HEADER}
@theme {
${themeLines.join("\n")}

${KEYFRAMES}
}

@layer base {
  [data-theme="dark"] {
${darkLines.join("\n")}
  }
}

${utilityBlocks.join("\n\n")}
`;

  writeFileSync(OUT, css);
  console.log(`tokens → ${OUT.replace(ROOT + "/", "")} (${themeLines.length} primitives, ${darkLines.length} dark overrides, ${utilityBlocks.length} utilities)`);
}

try {
  build();
} catch (err) {
  // Token errors are user-facing; the stack trace is noise.
  if (err.message?.startsWith("[tokens]")) {
    console.error(err.message);
    process.exit(1);
  }
  throw err;
}
