// Runtime axe-core/playwright pass over Lookbook previews.
// Captures color-contrast violations only, both light + dark themes.
// Output: /tmp/sure-screenshots/axe-audit.md
//
// Usage: BASE=http://127.0.0.1:3000 node tmp/axe-audit.mjs

import { chromium } from 'playwright';
import { AxeBuilder } from '@axe-core/playwright';
import fs from 'fs';

const BASE = process.env.BASE || 'http://127.0.0.1:3000';
const OUT = '/tmp/sure-screenshots/axe-audit.md';

const previews = [
  'alert/default?variant=info',
  'alert/default?variant=success',
  'alert/default?variant=warning',
  'alert/default?variant=error',
  'alert/with_title',
  'alert/with_body_slot',
  'button/default',
  'link/default',
  'dialog/modal',
  'dialog/drawer',
  'disclosure/default',
  'filled_icon/default',
  'filled_icon/text',
  'menu/button',
  'menu/avatar',
  'menu/icon',
  'tabs/default',
  'tabs/custom',
  'toggle/default',
  'tooltip/default',
  'tooltip/with_block_content',
  'design_tokens/palette',
  'design_tokens/surfaces',
  'design_tokens/text',
  'design_tokens/borders',
  'design_tokens/controls',
];

const findings = [];

for (const theme of ['light', 'dark']) {
  const browser = await chromium.launch();
  const ctx = await browser.newContext({
    viewport: { width: 1280, height: 900 },
    colorScheme: theme === 'dark' ? 'dark' : 'light',
  });
  await ctx.addInitScript((m) => document.documentElement.setAttribute('data-theme', m), theme);
  const page = await ctx.newPage();

  for (const p of previews) {
    const url = `${BASE}/design-system/preview/${p}`;
    try {
      await page.goto(url, { waitUntil: 'commit', timeout: 60000 });
      await page.evaluate((m) => document.documentElement.setAttribute('data-theme', m), theme);
      await page.waitForTimeout(300);

      const result = await new AxeBuilder({ page })
        .withTags(['wcag2aa', 'wcag2aaa', 'wcag21aa'])
        .options({ runOnly: { type: 'rule', values: ['color-contrast', 'color-contrast-enhanced', 'link-in-text-block'] } })
        .analyze();

      for (const v of result.violations) {
        for (const node of v.nodes) {
          findings.push({
            theme,
            preview: p,
            rule: v.id,
            impact: v.impact,
            help: v.help,
            target: node.target.join(' '),
            html: (node.html || '').slice(0, 200),
            summary: (node.failureSummary || '').replace(/\n/g, ' ').slice(0, 300),
          });
        }
      }
    } catch (e) {
      console.error(`fail [${theme}] ${p}: ${e.message.split('\n')[0]}`);
    }
  }

  await browser.close();
}

const md = [];
md.push('# DS contrast audit — runtime axe-core pass\n');
md.push(`Run on \`${BASE}\` over Lookbook previews. Tags: \`wcag2aa\`, \`wcag2aaa\`, \`wcag21aa\`. Rules: \`color-contrast\`, \`color-contrast-enhanced\`, \`link-in-text-block\`.\n`);
md.push(`Total violations: **${findings.length}**\n`);
md.push('| Theme | Preview | Rule | Impact | Target | Failure detail |');
md.push('|---|---|---|---|---|---|');
for (const f of findings) {
  md.push(`| ${f.theme} | \`${f.preview}\` | \`${f.rule}\` | ${f.impact ?? '?'} | \`${f.target.replace(/\|/g, '\\|').slice(0, 80)}\` | ${f.summary.replace(/\|/g, '\\|')} |`);
}

fs.writeFileSync(OUT, md.join('\n'));
console.log(`Wrote ${OUT} (${findings.length} violations).`);
