import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";
import vm from "node:vm";

// Run the actual controller without Rails, a browser, or a Stimulus dependency.
// Targets below model only the DOM API this controller uses.
const source = readFileSync(
  new URL("../../app/javascript/controllers/onboarding_provider_controller.js", import.meta.url),
  "utf8",
).replace('import { Controller } from "@hotwired/stimulus";', "class Controller {}")
  .replace("export default class extends Controller", "class ProviderController extends Controller");

function input(value = "") {
  return {
    value,
    disabled: false,
    focused: false,
    focus() { this.focused = true; },
    matches() { return this.disabled || this.fieldsetDisabled; },
  };
}

function harness(fetch, timers = {}) {
  const context = vm.createContext({
    fetch,
    AbortController,
    setTimeout,
    clearTimeout,
    document: { querySelector: () => null },
    ...timers,
  });
  const Controller = vm.runInContext(`${source}\nProviderController;`, context);

  return function build(provider = "openrouter", model = "openai/gpt-4.1-mini") {
    const controller = new Controller();
    controller.providerTarget = input(provider);
    controller.keyTarget = input("must-clear-on-connect");
    controller.modelTarget = input(model);
    controller.modelFieldsTarget = { hidden: false };
    controller.keyLabelTarget = {};
    controller.buttonTarget = input();
    controller.continueButton = input();
    controller.statusTarget = { textContent: "", classList: { toggle() {} } };
    controller.element = { closest: () => ({ querySelector: () => controller.continueButton }) };
    controller.optionsValue = Object.fromEntries(["openai", "anthropic", "openrouter"].map((name) => [name, {
      label: `${name} API key`, placeholder: `${name} key`,
    }]));
    controller.messagesValue = Object.fromEntries([
      "unchecked", "checking", "saved", "missing_key", "missing_model", "invalid_model",
      "connection_failed", "request_failed", "timed_out", "unauthorized",
    ].map((name) => [name, name]));
    controller.urlValue = "/onboarding/configure_provider";
    controller.connect();
    return controller;
  };
}

const click = { preventDefault() {} };
const response = (status, result) => ({ ok: status < 400, status, json: async () => result });

function pending() {
  let resolve;
  const promise = new Promise((done) => { resolve = done; });
  return { promise, resolve };
}

test("OpenRouter preserves its explicit model, never the saved key, and resets checks on edits", () => {
  const controller = harness(() => assert.fail("unexpected request"))();
  assert.equal(controller.modelTarget.value, "openai/gpt-4.1-mini");
  assert.equal(controller.modelFieldsTarget.hidden, false);
  assert.equal(controller.modelTarget.disabled, false);
  assert.equal(controller.keyTarget.value, "");
  assert.equal(controller.keyLabelTarget.textContent, "openrouter API key");
  controller.showStatus("saved");
  controller.editModel();
  assert.equal(controller.statusTarget.textContent, "unchecked");
  controller.showStatus("saved");
  controller.editKey();
  assert.equal(controller.statusTarget.textContent, "unchecked");
});

test("OpenRouter requires a nonblank model only for explicit save", async () => {
  const controller = harness(() => assert.fail("unexpected request"))("openrouter", " ");
  controller.keyTarget.value = "synthetic-key";
  await controller.save(click);
  assert.equal(controller.statusTarget.textContent, "missing_model");
  assert.equal(controller.modelTarget.focused, true);
  assert.equal(controller.continueButton.disabled, false);
  assert.equal(controller.keyTarget.value, "synthetic-key");
});

test("OpenRouter locks the model, prevents duplicate saves, and retries with the edited model", async () => {
  const requests = [];
  const first = pending();
  const build = harness((_url, options) => {
    requests.push(JSON.parse(options.body).ai_configuration);
    return requests.length === 1 ? first.promise : Promise.resolve(response(200, { status: "saved" }));
  });
  const controller = build();
  controller.keyTarget.value = "synthetic-key";
  const saving = controller.save(click);
  assert.equal(controller.modelTarget.disabled, true);
  assert.equal(controller.continueButton.disabled, true);
  await controller.save(click);
  assert.equal(requests.length, 1);
  first.resolve(response(422, { error: "connection_failed" }));
  await saving;
  assert.equal(controller.statusTarget.textContent, "connection_failed");
  assert.equal(controller.keyTarget.value, "");
  assert.equal(controller.modelTarget.value, "openai/gpt-4.1-mini");
  assert.equal(controller.modelTarget.disabled, false);
  assert.equal(controller.continueButton.disabled, false);

  controller.modelTarget.value = " anthropic/claude-sonnet-4 ";
  controller.editModel();
  controller.keyTarget.value = "synthetic-retry-key";
  await controller.save(click);
  assert.deepEqual(requests, [
    { provider: "openrouter", model: "openai/gpt-4.1-mini", api_key: "synthetic-key" },
    { provider: "openrouter", model: "anthropic/claude-sonnet-4", api_key: "synthetic-retry-key" },
  ]);
  assert.equal(controller.statusTarget.textContent, "saved");
  assert.equal(controller.keyTarget.value, "");
});

test("native providers hide the model, clear the key, and do not submit an OpenRouter model", async () => {
  let payload;
  const controller = harness((_url, options) => {
    payload = JSON.parse(options.body).ai_configuration;
    return Promise.resolve(response(200, { status: "saved" }));
  })();
  controller.keyTarget.value = "unsaved-key";
  controller.providerTarget.value = "anthropic";
  controller.changeProvider();
  assert.equal(controller.modelFieldsTarget.hidden, true);
  assert.equal(controller.modelTarget.disabled, true);
  assert.equal(controller.keyTarget.value, "");
  controller.keyTarget.value = "synthetic-anthropic-key";
  await controller.save(click);
  assert.deepEqual(payload, { provider: "anthropic", api_key: "synthetic-anthropic-key" });
  controller.providerTarget.value = "openrouter";
  controller.changeProvider();
  assert.equal(controller.modelTarget.value, "openai/gpt-4.1-mini");
  assert.equal(controller.modelTarget.disabled, false);
  assert.equal(controller.statusTarget.textContent, "unchecked");
});

test("navigation during a check clears secrets and blocks a restored controller until it finishes", async () => {
  const request = pending();
  let requests = 0;
  const build = harness(() => { requests += 1; return request.promise; });
  const previous = build();
  previous.keyTarget.value = "synthetic-key";
  const saving = previous.save(click);
  previous.beforeCache();
  previous.disconnect();
  assert.equal(previous.keyTarget.value, "");
  assert.equal(previous.modelTarget.value, "openai/gpt-4.1-mini");

  const restored = build();
  assert.equal(restored.modelTarget.disabled, true);
  assert.equal(restored.keyTarget.value, "");
  assert.equal(restored.continueButton.disabled, true);
  await restored.save(click);
  assert.equal(requests, 1);
  request.resolve(response(200, { status: "saved" }));
  await saving;
  await Promise.resolve();
  assert.equal(restored.modelTarget.disabled, false);
  assert.equal(restored.continueButton.disabled, false);
  assert.equal(restored.statusTarget.textContent, "request_failed");
  assert.equal(previous.statusTarget.textContent, "unchecked");
});

test("timeouts clear secrets, preserve the model, and allow an explicit retry", async () => {
  let timeout;
  let signal;
  const controller = harness((_url, options) => {
    signal = options.signal;
    return new Promise(() => {});
  }, { setTimeout: (callback) => { timeout = callback; return 1; }, clearTimeout() {} })();
  controller.keyTarget.value = "synthetic-key";
  const saving = controller.save(click);
  timeout();
  await saving;
  assert.equal(signal.aborted, true);
  assert.equal(controller.statusTarget.textContent, "timed_out");
  assert.equal(controller.keyTarget.value, "");
  assert.equal(controller.modelTarget.value, "openai/gpt-4.1-mini");
  assert.equal(controller.modelTarget.disabled, false);
  assert.equal(controller.buttonTarget.disabled, false);
});

test("disabled onboarding provider fieldsets cannot submit through a synthetic event", async () => {
  const controller = harness(() => assert.fail("unexpected request"))();
  controller.buttonTarget.fieldsetDisabled = true;
  controller.keyTarget.value = "synthetic-key";
  await controller.save(click);
  assert.equal(controller.statusTarget.textContent, "unchecked");
});


test("caching a completed save never preserves a checked status or typed key", () => {
  const controller = harness(() => assert.fail("unexpected request"))();
  controller.showStatus("saved");
  controller.keyTarget.value = "unsaved-replacement-key";
  controller.beforeCache();
  assert.equal(controller.keyTarget.value, "");
  assert.equal(controller.modelTarget.value, "openai/gpt-4.1-mini");
  assert.equal(controller.statusTarget.textContent, "unchecked");
});
