import assert from "node:assert/strict";
import { test } from "node:test";
import { readFile } from "node:fs/promises";

const source = (await readFile(new URL("../../app/javascript/controllers/split_transaction_controller.js", import.meta.url), "utf8"))
  .replace('import { Controller } from "@hotwired/stimulus"', "class Controller {}");
const { default: SplitController } = await import(`data:text/javascript;base64,${Buffer.from(source).toString("base64")}`);

test("new rows clone the server-rendered localized template with unique field names", () => {
  const instance = new SplitController();
  const rows = [];
  instance.rowTemplateTarget = {
    innerHTML: '<label for="split_splits_ROW_IDX_PLACEHOLDER_name">名称 &amp; montant</label>' +
      '<input id="split_splits_ROW_IDX_PLACEHOLDER_name" name="split[splits][ROW_IDX_PLACEHOLDER][name]" placeholder="&lt;script&gt;" />' +
      '<button aria-label="移除 &quot;synthetic&quot;"></button>',
  };
  instance.rowsContainerTarget = { insertAdjacentHTML(position, html) { rows.push({ position, html }); } };
  instance.updateRemaining = () => { instance.remainingUpdates = (instance.remainingUpdates || 0) + 1; };

  instance.addRow();
  instance.addRow();

  assert.equal(rows.length, 2);
  assert.equal(instance.remainingUpdates, 2);
  for (const row of rows) {
    assert.equal(row.position, "beforeend");
    assert.match(row.html, /名称 &amp; montant/);
    assert.match(row.html, /placeholder="&lt;script&gt;"/);
    assert.match(row.html, /aria-label="移除 &quot;synthetic&quot;"/);
    assert.doesNotMatch(row.html, /ROW_IDX_PLACEHOLDER/);
  }
  const indices = rows.map(({ html }) => html.match(/split\[splits\]\[(\d+)\]\[name\]/)[1]);
  assert.equal(Number(indices[1]), Number(indices[0]) + 1);
});
