// Static contrast audit for Sure's design-system tokens.
// No dependencies. Reads token definitions hard-coded below (mirrors
// `app/assets/tailwind/sure-design-system/_generated.css`); writes a
// Markdown report to `/tmp/sure-screenshots/contrast-audit.md`.
//
// To re-run after a token change:
//   node tmp/contrast-audit.mjs

import fs from 'fs';

// ---------- Color math ----------------------------------------------------

const lum = (h) =>
  [h.slice(1, 3), h.slice(3, 5), h.slice(5, 7)]
    .map((x) => parseInt(x, 16) / 255)
    .map((c) => (c <= 0.03928 ? c / 12.92 : Math.pow((c + 0.055) / 1.055, 2.4)))
    .reduce((acc, v, i) => acc + v * [0.2126, 0.7152, 0.0722][i], 0);

const blend = (bg, fg, alpha) => {
  const h = (s) => [s.slice(1, 3), s.slice(3, 5), s.slice(5, 7)].map((x) => parseInt(x, 16));
  const [br, bgg, bb] = h(bg);
  const [fr, fg2, fb] = h(fg);
  const r = Math.round(br * (1 - alpha) + fr * alpha);
  const g = Math.round(bgg * (1 - alpha) + fg2 * alpha);
  const b = Math.round(bb * (1 - alpha) + fb * alpha);
  return '#' + [r, g, b].map((x) => x.toString(16).padStart(2, '0')).join('');
};

const ratio = (fg, bg) => {
  const lf = lum(fg);
  const lb = lum(bg);
  const [hi, lo] = lf > lb ? [lf, lb] : [lb, lf];
  return (hi + 0.05) / (lo + 0.05);
};

// AA (normal text >=4.5, large text >=3, non-text/UI >=3)
// AAA (normal text >=7, large text >=4.5)
const classify = (r, kind) => {
  // kind: 'text' (normal), 'text-large' (>=18pt or 14pt bold), 'non-text' (icons/UI)
  if (kind === 'text') {
    if (r >= 7) return 'AAA';
    if (r >= 4.5) return 'AA';
    if (r >= 3) return 'AA-large only';
    return 'FAIL';
  }
  if (kind === 'text-large') {
    if (r >= 4.5) return 'AAA';
    if (r >= 3) return 'AA';
    return 'FAIL';
  }
  // non-text
  if (r >= 3) return 'PASS';
  return 'FAIL';
};

// ---------- Token table (mirrors _generated.css) -------------------------

const PALETTE = {
  white: '#FFFFFF',
  black: '#0B0B0B',
  'gray-25': '#FAFAFA',
  'gray-50': '#F7F7F7',
  'gray-100': '#F0F0F0',
  'gray-200': '#E7E7E7',
  'gray-300': '#CFCFCF',
  'gray-400': '#9E9E9E',
  'gray-500': '#737373',
  'gray-600': '#5C5C5C',
  'gray-700': '#363636',
  'gray-800': '#242424',
  'gray-900': '#171717',
  'red-400': '#ED4E4E',
  'red-500': '#F13636',
  'red-600': '#EC2222',
  'red-700': '#C91313',
  'green-400': '#32D583',
  'green-500': '#12B76A',
  'green-600': '#10A861',
  'green-700': '#078C52',
  'yellow-400': '#FDB022',
  'yellow-600': '#DC6803',
  'blue-500': '#2E90FA',
  'blue-600': '#1570EF',
};

// Theme-color tokens (single value per mode).
const THEME = {
  light: {
    success: PALETTE['green-600'],
    warning: PALETTE['yellow-600'],
    destructive: PALETTE['red-600'],
    info: PALETTE['blue-600'],
  },
  dark: {
    success: PALETTE['green-500'],
    warning: PALETTE['yellow-400'],
    destructive: PALETTE['red-400'],
    info: PALETTE['blue-500'],
  },
};

// Foreground (text) tokens: name -> hex per mode.
const FG = {
  light: {
    'text-primary': PALETTE['gray-900'],
    'text-secondary': PALETTE['gray-500'],
    'text-subdued': PALETTE['gray-400'],
    'text-inverse': PALETTE['white'],
    'text-link': PALETTE['blue-600'],
    'text-success': THEME.light.success,
    'text-warning': THEME.light.warning,
    'text-destructive': THEME.light.destructive,
    'text-info': THEME.light.info,
  },
  dark: {
    'text-primary': PALETTE['white'],
    'text-secondary': PALETTE['gray-300'],
    'text-subdued': PALETTE['gray-500'],
    'text-inverse': PALETTE['gray-900'],
    'text-link': PALETTE['blue-500'],
    'text-success': THEME.dark.success,
    'text-warning': THEME.dark.warning,
    'text-destructive': THEME.dark.destructive,
    'text-info': THEME.dark.info,
  },
};

// Surfaces. Solid hex per mode. Alpha-modifier surfaces are computed below.
const BG_SOLID = {
  light: {
    'bg-container': PALETTE['white'],
    'bg-container-hover': PALETTE['gray-50'],
    'bg-container-inset': PALETTE['gray-50'],
    'bg-container-inset-hover': PALETTE['gray-100'],
    'bg-surface': PALETTE['gray-50'],
    'bg-surface-hover': PALETTE['gray-100'],
    'bg-surface-inset': PALETTE['gray-100'],
    'bg-surface-inset-hover': PALETTE['gray-200'],
    'bg-inverse': PALETTE['gray-800'],
    'bg-inverse-hover': PALETTE['gray-700'],
    'button-bg-primary': PALETTE['gray-900'],
    'button-bg-primary-hover': PALETTE['gray-800'],
    'button-bg-secondary': PALETTE['gray-50'],
    'button-bg-secondary-hover': PALETTE['gray-100'],
    'button-bg-destructive': PALETTE['red-500'],
    'button-bg-destructive-hover': PALETTE['red-600'],
    'tab-item-active': PALETTE['white'],
    'tab-bg-group': PALETTE['gray-50'],
  },
  dark: {
    'bg-container': PALETTE['gray-900'],
    'bg-container-hover': PALETTE['gray-800'],
    'bg-container-inset': PALETTE['gray-800'],
    'bg-container-inset-hover': PALETTE['gray-700'],
    'bg-surface': PALETTE['black'],
    'bg-surface-hover': PALETTE['gray-800'],
    'bg-surface-inset': PALETTE['gray-800'],
    'bg-surface-inset-hover': PALETTE['gray-800'],
    'bg-inverse': PALETTE['white'],
    'bg-inverse-hover': PALETTE['gray-100'],
    'button-bg-primary': PALETTE['white'],
    'button-bg-primary-hover': PALETTE['gray-50'],
    'button-bg-secondary': PALETTE['gray-700'],
    'button-bg-secondary-hover': PALETTE['gray-600'],
    'button-bg-destructive': PALETTE['red-400'],
    'button-bg-destructive-hover': PALETTE['red-500'],
    'tab-item-active': PALETTE['gray-700'],
    'tab-bg-group': PALETTE['gray-50'], // (kept as in css)
  },
};

// Variant alpha surfaces: bg-{variant}/{N}, blended over bg-container.
function variantSurface(mode, variant, alphaPct) {
  return blend(BG_SOLID[mode]['bg-container'], THEME[mode][variant], alphaPct / 100);
}

const ALPHA_SURFACES_LIGHT = {};
const ALPHA_SURFACES_DARK = {};
for (const v of ['info', 'success', 'warning', 'destructive']) {
  for (const a of [5, 10, 20]) {
    ALPHA_SURFACES_LIGHT[`bg-${v}/${a} (over container)`] = variantSurface('light', v, a);
    ALPHA_SURFACES_DARK[`bg-${v}/${a} (over container)`] = variantSurface('dark', v, a);
  }
}

const BG = {
  light: { ...BG_SOLID.light, ...ALPHA_SURFACES_LIGHT },
  dark:  { ...BG_SOLID.dark,  ...ALPHA_SURFACES_DARK },
};

// ---------- Pair definitions ---------------------------------------------

// Plausible (fg, bg) pairs to check. Not the cartesian product — just the
// combinations that show up in DS components / view conventions.
function plausiblePairs(mode) {
  const fg = FG[mode];
  const bg = BG[mode];
  const pairs = [];

  // Text on default surfaces
  for (const surface of [
    'bg-container', 'bg-container-hover', 'bg-container-inset', 'bg-container-inset-hover',
    'bg-surface', 'bg-surface-hover', 'bg-surface-inset', 'bg-surface-inset-hover',
  ]) {
    for (const txt of ['text-primary', 'text-secondary', 'text-subdued', 'text-link']) {
      pairs.push([txt, fg[txt], surface, bg[surface], 'text']);
    }
  }

  // Inverse (e.g. button primary)
  for (const surface of ['bg-inverse', 'bg-inverse-hover', 'button-bg-primary', 'button-bg-primary-hover']) {
    pairs.push(['text-inverse', fg['text-inverse'], surface, bg[surface], 'text']);
  }

  // Destructive button
  for (const surface of ['button-bg-destructive', 'button-bg-destructive-hover']) {
    pairs.push(['text-inverse', fg['text-inverse'], surface, bg[surface], 'text']);
  }

  // Variant text on its own tinted surface (e.g. alerts)
  for (const v of ['info', 'success', 'warning', 'destructive']) {
    const fgKey = `text-${v}`;
    for (const a of [5, 10, 20]) {
      const surfaceKey = `bg-${v}/${a} (over container)`;
      // Body-on-tint (text-primary) — readability of body in alerts
      pairs.push(['text-primary', fg['text-primary'], surfaceKey, bg[surfaceKey], 'text']);
      pairs.push(['text-secondary', fg['text-secondary'], surfaceKey, bg[surfaceKey], 'text']);
      // Variant icon/text on its own surface — non-text 3:1 minimum applies
      pairs.push([fgKey, fg[fgKey], surfaceKey, bg[surfaceKey], 'non-text']);
    }
  }

  // Tab active item
  for (const txt of ['text-primary', 'text-secondary']) {
    pairs.push([txt, fg[txt], 'tab-item-active', bg['tab-item-active'], 'text']);
  }

  return pairs;
}

// ---------- Run ----------------------------------------------------------

const out = [];
out.push('# DS contrast audit — static token-pair pass\n');
out.push('Computed via `tmp/contrast-audit.mjs`. WCAG 2.1 ratios. AA for normal text = 4.5:1; AA for large text or non-text/UI = 3:1; AAA for normal text = 7:1.\n');

for (const mode of ['light', 'dark']) {
  out.push(`## ${mode === 'light' ? 'Light' : 'Dark'} mode\n`);
  out.push('| Foreground | Background | Foreground hex | Background hex | Ratio | Verdict |');
  out.push('|---|---|---|---|---|---|');

  const pairs = plausiblePairs(mode);
  for (const [fgName, fgHex, bgName, bgHex, kind] of pairs) {
    const r = ratio(fgHex, bgHex);
    const verdict = classify(r, kind);
    const flag = verdict === 'FAIL' ? '❌' : (verdict === 'AA-large only' ? '⚠️' : '✓');
    const kindHint = kind === 'non-text' ? ' *(non-text 3:1)*' : '';
    out.push(`| ${flag} \`${fgName}\`${kindHint} | \`${bgName}\` | \`${fgHex}\` | \`${bgHex}\` | ${r.toFixed(2)} | ${verdict} |`);
  }
  out.push('');
}

// ---------- Summary of failures -----------------------------------------

const fails = [];
for (const mode of ['light', 'dark']) {
  for (const [fgName, fgHex, bgName, bgHex, kind] of plausiblePairs(mode)) {
    const r = ratio(fgHex, bgHex);
    const v = classify(r, kind);
    if (v === 'FAIL' || v === 'AA-large only') {
      fails.push({ mode, fgName, bgName, fgHex, bgHex, kind, ratio: r, verdict: v });
    }
  }
}

out.push('## Summary of below-AA findings\n');
out.push('| Mode | Foreground | Background | Ratio | Verdict | Kind |');
out.push('|---|---|---|---|---|---|');
for (const f of fails) {
  out.push(`| ${f.mode} | \`${f.fgName}\` | \`${f.bgName}\` | ${f.ratio.toFixed(2)} | ${f.verdict} | ${f.kind} |`);
}

const path = '/tmp/sure-screenshots/contrast-audit.md';
fs.mkdirSync('/tmp/sure-screenshots', { recursive: true });
fs.writeFileSync(path, out.join('\n'));
console.log(`Wrote ${path} (${fails.length} below-AA findings).`);
