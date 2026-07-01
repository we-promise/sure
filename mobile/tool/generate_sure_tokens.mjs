#!/usr/bin/env node
import { readFileSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
const TOKENS_PATH = resolve(ROOT, "design/tokens/sure.tokens.json");
const OUT_PATH = resolve(ROOT, "mobile/lib/theme/sure_tokens.dart");

const COLOR_TOKENS = [
  ["surface", "color.surface"],
  ["surfaceHover", "color.surface-hover"],
  ["surfaceInset", "color.surface-inset"],
  ["surfaceInsetHover", "color.surface-inset-hover"],
  ["container", "color.container"],
  ["containerHover", "color.container-hover"],
  ["containerInset", "color.container-inset"],
  ["containerInsetHover", "color.container-inset-hover"],
  ["success", "color.success"],
  ["warning", "color.warning"],
  ["destructive", "color.destructive"],
  ["destructiveSubtle", "color.destructive-subtle"],
  ["info", "color.info"],
  ["link", "color.link"],
  ["shadow", "color.shadow"],
  ["focusRing", "color.focus-ring"],
  ["bgInverse", "utility.bg-inverse"],
  ["textPrimary", "utility.text-primary"],
  ["textInverse", "utility.text-inverse"],
  ["textSecondary", "utility.text-secondary"],
  ["textSubdued", "utility.text-subdued"],
  ["borderPrimary", "utility.border-primary"],
  ["borderSecondary", "utility.border-secondary"],
  ["borderSubdued", "utility.border-subdued"],
  ["buttonPrimary", "utility.button-bg-primary"],
  ["buttonPrimaryHover", "utility.button-bg-primary-hover"],
  ["buttonDestructive", "utility.button-bg-destructive"],
  ["buttonDestructiveHover", "utility.button-bg-destructive-hover"],
];

const RADIUS_TOKENS = [
  ["radiusMd", "border.radius.md"],
  ["radiusLg", "border.radius.lg"],
];

// Named font-weight tiers, mirroring the web DS's Tailwind weight utilities
// (font-medium / font-semibold) so widgets reference a named token instead of a
// raw FontWeight.
const WEIGHT_TOKENS = [
  ["weightMedium", "font.weight.medium"],
  ["weightSemibold", "font.weight.semibold"],
];

// Single-layer elevation scale (shadow/*). Mode-aware: each token carries a
// `sure.dark` extension, so light/dark emit different shadow colors.
const SHADOW_TOKENS = [
  ["shadowXs", "shadow.xs"],
  ["shadowSm", "shadow.sm"],
  ["shadowMd", "shadow.md"],
  ["shadowLg", "shadow.lg"],
  ["shadowXl", "shadow.xl"],
];

function readTokens() {
  return JSON.parse(readFileSync(TOKENS_PATH, "utf8"));
}

function nodeAt(tokens, path) {
  const node = path.split(".").reduce((current, part) => current?.[part], tokens);
  if (!node || typeof node !== "object") {
    throw new Error(`[mobile-tokens] Unknown token path: ${path}`);
  }
  return node;
}

function valueForMode(node, mode) {
  if (mode === "dark" && node.$extensions?.["sure.dark"] !== undefined) {
    return node.$extensions["sure.dark"];
  }
  if (node.$value === undefined) {
    throw new Error("[mobile-tokens] Token is missing $value");
  }
  return node.$value;
}

function resolveColor(tokens, path, mode) {
  const node = nodeAt(tokens, path);
  const value = valueForMode(node, mode);
  return resolveColorValue(tokens, value, mode, path);
}

function resolveColorValue(tokens, value, mode, sourcePath) {
  if (typeof value !== "string") {
    throw new Error(`[mobile-tokens] ${sourcePath} must resolve to a string color`);
  }

  const hexMatch = value.match(/^#([0-9a-fA-F]{6})$/);
  if (hexMatch) {
    return `0xFF${hexMatch[1].toUpperCase()}`;
  }

  const refMatch = value.match(/^\{([^|}]+)(?:\|([0-9]+)%?)?\}$/);
  if (refMatch) {
    const [, ref, alphaPercent] = refMatch;
    const resolved = resolveColor(tokens, ref, mode);
    if (!alphaPercent) return resolved;

    const alpha = Math.round((Number(alphaPercent) / 100) * 255);
    if (!Number.isFinite(alpha) || alpha < 0 || alpha > 255) {
      throw new Error(`[mobile-tokens] Invalid alpha in ${sourcePath}: ${alphaPercent}`);
    }
    return `0x${alpha.toString(16).toUpperCase().padStart(2, "0")}${resolved.slice(4)}`;
  }

  throw new Error(`[mobile-tokens] ${sourcePath} has unsupported color value: ${value}`);
}

function resolveDimension(tokens, path) {
  const node = nodeAt(tokens, path);
  const value = valueForMode(node, "light");
  const match = String(value).match(/^([0-9]+(?:\.[0-9]+)?)px$/);
  if (!match) {
    throw new Error(`[mobile-tokens] ${path} must be a px dimension`);
  }
  return Number(match[1]).toFixed(1);
}

function resolveWeight(tokens, path) {
  const node = nodeAt(tokens, path);
  const value = Number(valueForMode(node, "light"));
  if (!Number.isInteger(value) || value < 100 || value > 900 || value % 100 !== 0) {
    throw new Error(`[mobile-tokens] ${path} must be a font weight (100-900 in steps of 100)`);
  }
  return `FontWeight.w${value}`;
}

// Parse a single-layer CSS box-shadow ("<x>px <y>px <blur>px <spread>px {color}")
// into a Dart `BoxShadow(...)` literal. Offsets and spread may be negative
// (e.g. -4px); blur must be >= 0. A strict number pattern rejects malformed
// dimensions (e.g. "1.2.3px") instead of emitting NaN into the generated Dart.
function resolveShadow(tokens, path, mode) {
  const node = nodeAt(tokens, path);
  const value = valueForMode(node, mode);
  const num = "-?[0-9]+(?:\\.[0-9]+)?";
  const nonNeg = "[0-9]+(?:\\.[0-9]+)?";
  const match = String(value).match(
    new RegExp(`^(${num})px (${num})px (${nonNeg})px (${num})px (\\{[^}]+\\})$`),
  );
  if (!match) {
    throw new Error(`[mobile-tokens] ${path} must be a single-layer box shadow: ${value}`);
  }
  const [, offsetX, offsetY, blur, spread, colorRef] = match;
  const color = resolveColorValue(tokens, colorRef, mode, path);
  const px = (raw) => Number(raw).toFixed(1);
  return (
    `BoxShadow(color: Color(${color}), ` +
    `offset: Offset(${px(offsetX)}, ${px(offsetY)}), ` +
    `blurRadius: ${px(blur)}, spreadRadius: ${px(spread)})`
  );
}

function firstFontFamily(stack) {
  for (const rawFamily of stack.split(",")) {
    const family = rawFamily.trim();
    if (!family) continue;

    return family.replace(/^['"](.+)['"]$/, "$1");
  }

  throw new Error(`[mobile-tokens] Unsupported font stack: ${stack}`);
}

function emitPalette(tokens, mode) {
  const colorLines = COLOR_TOKENS.map(
    ([name, path]) => `    ${name}: Color(${resolveColor(tokens, path, mode)}),`,
  );
  const shadowLines = SHADOW_TOKENS.map(
    ([name, path]) => `    ${name}: [${resolveShadow(tokens, path, mode)}],`,
  );

  return `  static const ${mode} = SureTokenPalette(\n${colorLines.join("\n")}\n${shadowLines.join("\n")}\n  );`;
}

function buildDart(tokens) {
  const fontSans = firstFontFamily(tokens.font.sans.$value);
  const fontMono = firstFontFamily(tokens.font.mono.$value);
  const radiusLines = RADIUS_TOKENS.map(
    ([name, path]) => `  static const double ${name} = ${resolveDimension(tokens, path)};`,
  );
  const weightLines = WEIGHT_TOKENS.map(
    ([name, path]) => `  static const FontWeight ${name} = ${resolveWeight(tokens, path)};`,
  );

  return `// GENERATED CODE - DO NOT EDIT BY HAND.
// Source: design/tokens/sure.tokens.json
// Build: node mobile/tool/generate_sure_tokens.mjs

import 'package:flutter/painting.dart';

class SureTokens {
  const SureTokens._();

  static const String version = '${tokens.$version}';
  static const String fontSans = '${fontSans}';
  static const String fontMono = '${fontMono}';

  // Keep the existing Flutter fallback behavior until native mobile font assets
  // are registered. The canonical web stack remains in sure.tokens.json.
  static const List<String> fontFallback = <String>[
    'Inter',
    'Arial',
    'sans-serif',
  ];

${radiusLines.join("\n")}

${weightLines.join("\n")}

${emitPalette(tokens, "light")}

${emitPalette(tokens, "dark")}
}

class SureTokenPalette {
  const SureTokenPalette({
${COLOR_TOKENS.map(([name]) => `    required this.${name},`).join("\n")}
${SHADOW_TOKENS.map(([name]) => `    required this.${name},`).join("\n")}
  });

${COLOR_TOKENS.map(([name]) => `  final Color ${name};`).join("\n")}
${SHADOW_TOKENS.map(([name]) => `  final List<BoxShadow> ${name};`).join("\n")}
}
`;
}

function main() {
  const check = process.argv.includes("--check");
  const tokens = readTokens();
  const output = buildDart(tokens);

  if (check) {
    let existing;
    try {
      existing = readFileSync(OUT_PATH, "utf8");
    } catch (error) {
      if (error.code === "ENOENT") {
        console.error(
          "[mobile-tokens] mobile/lib/theme/sure_tokens.dart is missing. " +
            "Run node mobile/tool/generate_sure_tokens.mjs.",
        );
        process.exit(1);
      }
      throw error;
    }
    if (existing !== output) {
      console.error(
        "[mobile-tokens] mobile/lib/theme/sure_tokens.dart is stale. " +
          "Run node mobile/tool/generate_sure_tokens.mjs.",
      );
      process.exit(1);
    }
    console.log("[mobile-tokens] generated Dart tokens are current");
    return;
  }

  writeFileSync(OUT_PATH, output);
  console.log(`mobile tokens -> ${OUT_PATH.replace(ROOT + "/", "")}`);
}

try {
  main();
} catch (error) {
  if (error.message?.startsWith("[mobile-tokens]")) {
    console.error(error.message);
    process.exit(1);
  }
  throw error;
}
