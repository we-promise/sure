import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";
import vm from "node:vm";

const source = readFileSync(
  new URL(
    "../../app/javascript/controllers/onboarding_handoff_controller.js",
    import.meta.url,
  ),
  "utf8",
)
  .replace(
    'import { Controller } from "@hotwired/stimulus";',
    "class Controller {}",
  )
  .replace(
    "export default class extends Controller",
    "class HandoffController extends Controller",
  );

const instructions =
  "Help me get started at https://money.example.test:8443/household&shared.\n\n" +
  "• MCP: Connect to https://money.example.test:8443/household&shared/mcp.\n\n" +
  "• Sure CLI: Have me run `sure-cli login` in my own terminal.";

function harness(clipboard) {
  const context = vm.createContext({ navigator: { clipboard } });
  const Controller = vm.runInContext(`${source}\nHandoffController;`, context);
  const controller = new Controller();
  controller.sourceTarget = {
    value: instructions,
    focus() {
      this.focused = true;
    },
    select() {
      this.selected = true;
    },
  };
  controller.statusTarget = { textContent: "" };
  controller.copiedValue = "Instructions copied.";
  controller.fallbackValue = "Copy manually.";
  return controller;
}

test("copies multiline instructions and instance URLs unchanged", async () => {
  const copied = [];
  const controller = harness({
    writeText: async (value) => copied.push(value),
  });

  await controller.copy();
  await controller.copy();

  assert.deepEqual(copied, [instructions, instructions]);
  assert.equal(controller.statusTarget.textContent, "Instructions copied.");
});

test("selects the same multiline instructions when clipboard access fails", async () => {
  const controller = harness({
    writeText: async () => {
      throw new Error("Denied");
    },
  });

  await controller.copy();

  assert.equal(controller.sourceTarget.value, instructions);
  assert.equal(controller.sourceTarget.focused, true);
  assert.equal(controller.sourceTarget.selected, true);
  assert.equal(controller.statusTarget.textContent, "Copy manually.");
});

test("supports manual copy when the clipboard API is unavailable", async () => {
  const controller = harness(undefined);

  await controller.copy();

  assert.equal(controller.sourceTarget.value, instructions);
  assert.equal(controller.sourceTarget.selected, true);
  assert.equal(controller.statusTarget.textContent, "Copy manually.");
});
