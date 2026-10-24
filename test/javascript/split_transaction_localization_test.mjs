import assert from "node:assert/strict";
import { test } from "node:test";
import { readFile } from "node:fs/promises";

// Run the real action without Rails/browser dependencies. The small DOM double
// models the fields touched by addRow; text/property assignments remain separate
// from HTML parsing so hostile-looking translations exercise the safe boundary.
const source = (await readFile(new URL("../../app/javascript/controllers/split_transaction_controller.js", import.meta.url), "utf8"))
  .replace('import { Controller } from "@hotwired/stimulus"', "class Controller {}");
const { default: SplitController } = await import(`data:text/javascript;base64,${Buffer.from(source).toString("base64")}`);

function element(attributes = {}, textContent = "") {
  return {
    attributes, textContent, dataset: {}, value: "", classList: { add() {}, remove() {}, contains() { return false; } },
    setAttribute(key, value) { this.attributes[key] = value; },
    getAttribute(key) { return this.attributes[key]; },
  };
}
function attributes(markup) {
  return Object.fromEntries([...markup.matchAll(/([\w-]+)="([^"]*)"/g)].map((match) => [match[1], match[2]]));
}
function row() {
  const result = element();
  Object.defineProperty(result, "innerHTML", {
    set(markup) {
      this.markup = markup;
      this.labels = [...markup.matchAll(/<label([^>]*)>(.*?)<\/label>/gs)].map((match) => element(attributes(match[1]), match[2]));
      this.inputs = [...markup.matchAll(/<input\b((?:"[^"]*"|'[^']*'|[^'">])*)>/gs)].map((match) => {
        const attrs = attributes(match[1]);
        return Object.assign(element(attrs), { name: attrs.name, placeholder: attrs.placeholder || "" });
      });
      this.button = element(attributes(markup.match(/<button\b((?:"[^"]*"|'[^']*'|[^'">])*)>/s)?.[1] || ""));
    },
  });
  result.querySelector = function (selector) {
    const match = selector.match(/^\[([^=]+)=["']([^"']+)["']\]$/);
    return [...this.labels, ...this.inputs, this.button].find((node) => node.attributes[match?.[1]] === match?.[2]) || null;
  };
  return result;
}

function controller(labels, category = null) {
  const instance = new SplitController();
  instance.labelsValue = labels;
  instance.rowTargets = [{ name: "Untouched synthetic user name" }];
  instance.rowsContainerTarget = {
    children: [], querySelector() { return category; },
    appendChild(child) { this.children.push(child); },
  };
  instance.updateRemaining = () => { instance.remainingUpdates = (instance.remainingUpdates || 0) + 1; };
  return instance;
}

globalThis.document = { createElement: row };

for (const labels of [
  { name: "名称", amount: "金额", name_placeholder: "拆分名称", uncategorized: "（未分类）", remove: "移除" },
  { name: "Naam", amount: "Bedrag", name_placeholder: "Naam van deeltransactie", uncategorized: "(geen categorie)", remove: "Verwijderen" },
  { name: '<img src=x onerror="throw 1">', amount: "O'Brien & bedrag", name_placeholder: '" <script>synthetic</script>', uncategorized: "<b>none</b>", remove: 'Remove "synthetic"' },
]) {
  test(`new split rows use supplied labels as text: ${labels.name}`, () => {
    const instance = controller(labels);
    instance.addRow();
    const added = instance.rowsContainerTarget.children[0];
    assert.deepEqual(added.labels.map((label) => label.textContent), [labels.name, labels.amount]);
    const name = added.inputs.find((input) => input.name.endsWith("[name]"));
    assert.equal(name.placeholder, labels.name_placeholder);
    assert.equal(name.name, "split[splits][1][name]");
    assert.equal(added.inputs.find((input) => input.name.endsWith("[amount]")).name, "split[splits][1][amount]");
    assert.equal(added.button.attributes["aria-label"], labels.remove);
    assert.equal(added.button.attributes["data-action"], "click->split-transaction#removeRow");
    assert.equal(instance.remainingUpdates, 1);
    assert.equal(instance.rowTargets[0].name, "Untouched synthetic user name");
    assert.ok(!added.markup.includes(labels.name), "Translation is assigned as text rather than embedded into HTML");
    assert.ok(!added.markup.includes(labels.name_placeholder));
  });
}

test("missing blank category option uses the localized fallback as text", () => {
  const button = element();
  Object.defineProperty(button, "innerHTML", { set() { throw new Error("Category labels must not be interpreted as HTML"); } });
  const hidden = { value: "old-category", name: "old-name" };
  const clone = {
    outerHTML: '<div class="category-select-container"></div>',
    querySelector(selector) {
      if (selector === "input[type='hidden']") return hidden;
      if (selector === "[data-select-target='button']") return button;
      return null;
    },
    querySelectorAll() { return []; },
  };
  const labels = { name: "Nom", amount: "Montant", name_placeholder: "Nom de la partie", uncategorized: "<sans catégorie>", remove: "Retirer" };
  const instance = controller(labels, { cloneNode() { return clone; } });
  instance.addRow();
  assert.equal(button.textContent, labels.uncategorized);
  assert.equal(button.attributes["aria-expanded"], "false");
  assert.equal(hidden.value, "");
  assert.equal(hidden.name, "split[splits][1][category_id]");
});
