import assert from "node:assert/strict";
import { test } from "node:test";
import { readFile } from "node:fs/promises";

// Exercise the actual action methods without starting Rails or a browser. Only
// Stimulus attachment and the unrelated color picker dependency are replaced.
const source = (await readFile(new URL("../../app/javascript/controllers/color_icon_picker_controller.js", import.meta.url), "utf8"))
  .replace('import { Controller } from "@hotwired/stimulus";', "class Controller {}")
  .replace('import Pickr from "@simonwep/pickr";', "const Pickr = {};");
const { default: Picker } = await import(`data:text/javascript;base64,${Buffer.from(source).toString("base64")}`);

function node(kind = "span") {
  return {
    kind, dataset: {}, style: {}, textContent: "", children: [], attributes: {},
    classList: { add() {}, remove() {} },
    setAttribute(key, value) { this.attributes[key] = value; },
    replaceChildren(...children) { this.children = children; },
    appendChild(child) { this.children.push(child); },
    prepend(child) { this.children.unshift(child); },
    cloneNode() { const copy = node(this.kind); copy.textContent = this.textContent; return copy; },
  };
}

globalThis.document = { createElement: node };

function picker() {
  const result = new Picker();
  result.hasEmojiInputTarget = true;
  result.emojiInputTarget = { value: "" };
  result.avatarTarget = node("avatar");
  result.fallbackIcon = node("coffee-svg");
  return result;
}

test("emoji typing and quick selection preserve complete Unicode sequences", () => {
  const controller = picker();
  for (const emoji of ["👨‍👩‍👧‍👦", "👩🏽‍💻", "🇨🇳", "1️⃣", "❤️"]) {
    controller.emojiInputTarget.value = emoji;
    controller.handleEmojiInput();
    assert.equal(controller.avatarTarget.children[0].textContent, emoji);
    assert.equal(controller.emojiInputTarget.value, emoji);
    assert.equal(controller.avatarTarget.children[0].attributes["aria-hidden"], "true");
  }
  controller.selectEmoji({ currentTarget: { dataset: { emoji: "👩🏽‍💻" } } });
  assert.equal(controller.emojiInputTarget.value, "👩🏽‍💻");
  assert.equal(controller.avatarTarget.children[0].textContent, "👩🏽‍💻");
});

test("clear and repeated icon switching restore the selected Lucide fallback", () => {
  const controller = picker();
  controller.selectEmoji({ currentTarget: { dataset: { emoji: "🇨🇳" } } });
  controller.clearEmoji();
  assert.equal(controller.emojiInputTarget.value, "");
  assert.equal(controller.avatarTarget.children[0].kind, "coffee-svg");
  controller.selectEmoji({ currentTarget: { dataset: { emoji: "❤️" } } });
  const selected = { closest: () => ({ querySelector: () => node("home-svg") }) };
  controller.handleIconChange({ currentTarget: selected });
  assert.equal(controller.emojiInputTarget.value, "");
  assert.equal(controller.avatarTarget.children[0].kind, "home-svg");
  controller.selectEmoji({ currentTarget: { dataset: { emoji: "👨‍👩‍👧‍👦" } } });
  controller.clearEmoji();
  assert.equal(controller.avatarTarget.children[0].kind, "home-svg");
});

test("the shared picker still switches goal icons without emoji targets", () => {
  const controller = picker();
  controller.hasEmojiInputTarget = false;
  const selected = { closest: () => ({ querySelector: () => node("goal-svg") }) };
  controller.handleIconChange({ currentTarget: selected });
  assert.equal(controller.avatarTarget.children[0].kind, "goal-svg");
  controller.handleEmojiInput();
  assert.equal(controller.avatarTarget.children[0].kind, "goal-svg");
});

const selectSource = (await readFile(new URL("../../app/javascript/controllers/select_controller.js", import.meta.url), "utf8"))
  .replace('import { Controller } from "@hotwired/stimulus"', "class Controller {}")
  .replace('import { autoUpdate } from "@floating-ui/dom"', "const autoUpdate = () => {};");
const { default: Select } = await import(`data:text/javascript;base64,${Buffer.from(selectSource).toString("base64")}`);

test("generic badge selection keeps the whole emoji without changing its submitted label or ID", () => {
  const controller = new Select();
  controller.buttonTarget = node("button");
  controller.hasInputTarget = false;
  controller.menuTarget = { querySelector: () => null };
  let dispatched;
  controller.element = { dispatchEvent(event) { dispatched = event.detail; } };
  controller.focusTriggerWithoutReopening = () => {};
  controller.close = () => {};
  const glyph = node(); glyph.textContent = "👩🏽‍💻";
  const selected = node("option");
  selected.dataset = { value: "synthetic-id", filterName: "Synthetic label" };
  selected.querySelector = (selector) => selector === "[data-emoji-glyph]" ? glyph : null;
  controller.select({ currentTarget: selected });
  assert.equal(controller.buttonTarget.children[0].textContent, "👩🏽‍💻");
  assert.equal(controller.buttonTarget.textContent, "Synthetic label");
  assert.deepEqual(dispatched, { value: "synthetic-id", label: "Synthetic label" });
});

for (const [locale, sourceMessage, expected] of [
  ["zh-CN", "\n  对比度较低，请选择更深的颜色或\n    自动调整。\n", "对比度较低，请选择更深的颜色或 自动调整。"],
  ["en", "\n  Poor contrast, choose a darker color or\n    auto-adjust.\n", "Poor contrast, choose a darker color or auto-adjust."],
]) {
  test(`contrast validation uses the existing ${locale} message and clears on recovery`, () => {
    const controller = picker();
    controller.hasValidationMessageTarget = true;
    controller.validationMessageTarget = node();
    controller.validationMessageTarget.textContent = sourceMessage;
    controller.colorInputTarget = { setCustomValidity(value) { this.customMessage = value; } };
    controller.handleContrastValidation(2);
    assert.equal(controller.colorInputTarget.customMessage, expected);
    controller.handleContrastValidation(5);
    assert.equal(controller.colorInputTarget.customMessage, "");
  });
}

test("missing contrast message leaves native input validation available without an English fallback", () => {
  const controller = picker();
  controller.hasValidationMessageTarget = false;
  Object.defineProperty(controller, "validationMessageTarget", { get() { throw new Error("Missing Stimulus target"); } });
  controller.colorInputTarget = {
    customMessage: "Previous custom error",
    nativeMessage: "请与所请求的格式保持一致。",
    setCustomValidity(value) { this.customMessage = value; },
    get validationMessage() { return this.customMessage || this.nativeMessage; },
  };
  controller.handleContrastValidation(2);
  assert.equal(controller.colorInputTarget.customMessage, "");
  assert.equal(controller.colorInputTarget.validationMessage, "请与所请求的格式保持一致。");
});
