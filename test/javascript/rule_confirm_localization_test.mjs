import assert from "node:assert/strict";
import { test } from "node:test";
import { readFile } from "node:fs/promises";

async function load(path) {
  const source = (await readFile(new URL(`../../app/javascript/controllers/${path}`, import.meta.url), "utf8"))
    .replace('import { Controller } from "@hotwired/stimulus";', "class Controller {}")
    .replace('import { autoUpdate } from "@floating-ui/dom";', "const autoUpdate = () => {};");
  return (await import(`data:text/javascript;base64,${Buffer.from(source).toString("base64")}`)).default;
}
const Conditions = await load("rule/conditions_controller.js");
const Actions = await load("rule/actions_controller.js");
const Tags = await load("tag_select_controller.js");
const Confirm = await load("confirm_dialog_controller.js");
function node() {
  const el = {
    textContent: "", value: "", id: "synthetic-id", name: "synthetic-name", children: [], dataset: {}, attributes: {},
    classList: { add() {}, remove() {}, toggle() {}, contains() { return false; }, *[Symbol.iterator]() { yield "synthetic-class"; } },
    appendChild(child) { this.children.push(child); },
    setAttribute(key, value) { this.attributes[key] = value; },
    removeAttribute(key) { delete this.attributes[key]; }, focus() {},
  };
  Object.defineProperty(el, "innerHTML", { set(value) { assert.equal(value, "", "Never parse labels or supplied text as HTML"); this.children = []; } });
  return el;
}
globalThis.document = { createElement: node, querySelector() { return { content: "synthetic-csrf" }; } };

for (const placeholder of ["请输入值", "Wert eingeben", '<img src=x onerror="synthetic()">']) {
  test(`rule condition changes use the supplied placeholder as a property: ${placeholder}`, () => {
    const controller = new Conditions();
    controller.valuePlaceholderValue = placeholder;
    controller.conditionFiltersValue = [{ key: "synthetic", type: "text", operators: [["包含", "like"]] }];
    controller.valuelessOperatorsValue = [];
    controller.operatorSelectTarget = node();
    controller.operatorSelectTarget.value = "like";
    let input = node();
    input.replaceWith = (replacement) => { input = replacement; };
    controller.filterValueTarget = Object.assign(node(), { querySelector(selector) { return selector === "input" ? input : null; } });
    controller.handleConditionTypeChange({ target: { value: "synthetic" } });
    assert.equal(input.placeholder, placeholder);
    assert.equal(input.name, "synthetic-name");
    assert.equal(input.id, "synthetic-id");
    assert.equal(input.type, "text");
    assert.equal(controller.operatorSelectTarget.children[0].textContent, "包含");
  });
}
test("empty rule action options use the localized none label without HTML", () => {
  const controller = new Actions();
  controller.noneLabelValue = "（无可选项）<b>text</b>";
  controller.actionExecutorsValue = [{ key: "empty", type: "select", options: [] }];
  const select = node();
  controller.selectTemplateTarget = { content: { cloneNode() { return { querySelector() { return select; } }; } } };
  controller.actionValueTarget = node();
  controller.handleActionTypeChange({ target: { value: "empty" } });
  assert.equal(select.disabled, true);
  assert.equal(select.children[0].textContent, controller.noneLabelValue);
});

test("non-JSON tag creation failure uses the supplied fallback and preserves user input", async () => {
  const controller = new Tags();
  controller.searchTarget = node(); controller.searchTarget.value = '<img src=x> Synthetic user tag';
  controller.createFormTarget = node(); controller.createErrorTarget = node();
  controller.hasCreateErrorTarget = true; controller.createErrorValue = "无法创建标签";
  controller.createUrlValue = "/synthetic/tags"; controller.defaultColorValue = "#123456";
  let request;
  const originalFetch = globalThis.fetch;
  globalThis.fetch = async (url, options) => { request = { url, options }; return { ok: false, async json() { throw new Error("synthetic non-JSON response"); } }; };
  try {
    await controller.createTag();
    assert.equal(controller.createErrorTarget.textContent, "无法创建标签");
    assert.equal(JSON.parse(request.options.body).tag.name, controller.searchTarget.value);
    assert.equal(controller.searchTarget.attributes["aria-invalid"], "true");
    assert.equal(controller.createFormTarget.disabled, false);
    assert.equal(controller.creating, false);
  } finally { globalThis.fetch = originalFetch; }
});

function dialog() {
  const controller = new Confirm();
  controller.labelsValue = { are_you_sure: "确定要继续吗？", cannot_be_undone: "此操作无法撤销。", confirm: "确认" };
  controller.titleTarget = node(); controller.subtitleTarget = node();
  controller.confirmButtonTargets = ["primary", "outline-destructive", "destructive"].map((variant) => Object.assign(node(), { dataset: { variant } }));
  controller.element = { returnValue: "", showModal() {}, addEventListener(type, callback, options) { assert.equal(type, "close"); assert.equal(options.once, true); this.closeCallback = callback; } };
  return controller;
}
for (const raw of [true, false, "true", "false", "{}", "null"]) {
  test(`confirmation ${JSON.stringify(raw)} retains the localized default and cancel semantics`, async () => {
    const controller = dialog(); const promise = controller.handleConfirm(raw);
    assert.equal(controller.titleTarget.textContent, "确定要继续吗？");
    assert.equal(controller.subtitleTarget.textContent, "此操作无法撤销。");
    assert.ok(controller.confirmButtonTargets.every((button) => button.textContent === "确认"));
    controller.element.returnValue = "cancel"; controller.element.closeCallback();
    assert.equal(await promise, false);
  });
}
for (const wrap of [(s) => s, JSON.stringify]) {
  test("custom string confirmation remains literal text with localized fallbacks", async () => {
    const controller = dialog(); const title = '<img src=x onerror="synthetic()"> & user title';
    const promise = controller.handleConfirm(wrap(title));
    assert.equal(controller.titleTarget.textContent, title);
    assert.equal(controller.subtitleTarget.textContent, "此操作无法撤销。");
    controller.element.returnValue = "confirm"; controller.element.closeCallback();
    assert.equal(await promise, true);
  });
}
test("object confirmation preserves explicit text and destructive variant, then resets to localized defaults", async () => {
  const controller = dialog();
  const promise = controller.handleConfirm(JSON.stringify({ title: "Synthetic title", body: "<b>literal user body</b>", confirmText: "Custom action", variant: "destructive" }));
  assert.equal(controller.subtitleTarget.textContent, "<b>literal user body</b>");
  assert.equal(controller.confirmButtonTargets[2].attributes.hidden, undefined);
  assert.equal(controller.confirmButtonTargets[0].attributes.hidden, true);
  controller.element.returnValue = "confirm"; controller.element.closeCallback(); assert.equal(await promise, true);
  const second = controller.handleConfirm(true);
  assert.equal(controller.titleTarget.textContent, "确定要继续吗？");
  assert.equal(controller.subtitleTarget.textContent, "此操作无法撤销。");
  assert.equal(controller.confirmButtonTargets[0].textContent, "确认");
  controller.element.returnValue = "cancel"; controller.element.closeCallback(); assert.equal(await second, false);
});

// Stimulus singular target getters throw for missing targets; has*Target is the
// supported presence check. Compound hosts own templates/lists, not leaf inputs.
test("compound condition connect does not access missing leaf targets", () => {
  const controller = new Conditions();
  controller.hasOperatorSelectTarget = false;
  controller.hasFilterValueTarget = false;
  for (const target of ["operatorSelect", "filterValue"]) {
    Object.defineProperty(controller, `${target}Target`, {
      get() { throw new Error(`Missing target element "${target}" for "rule--conditions" controller`); },
    });
  }
  assert.doesNotThrow(() => controller.connect());
});

for (const operator of ["is_null", "like"]) {
  test(`leaf condition connect retains initial field behavior for ${operator}`, () => {
    const controller = new Conditions();
    controller.hasOperatorSelectTarget = true;
    controller.hasFilterValueTarget = true;
    controller.valuelessOperatorsValue = ["is_null", "is_not_null"];
    controller.operatorSelectTarget = { value: operator };
    const input = { value: "Synthetic user content" };
    const classes = new Set(["hidden"]);
    controller.filterValueTarget = {
      classList: { add(value) { classes.add(value); }, remove(value) { classes.delete(value); } },
      querySelector(selector) { return selector === "input" ? input : null; },
    };
    controller.connect();
    assert.equal(classes.has("hidden"), operator === "is_null");
    assert.equal(input.value, operator === "is_null" ? "" : "Synthetic user content");
  });
}
