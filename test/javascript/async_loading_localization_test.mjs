import assert from "node:assert/strict";
import { test } from "node:test";
import { readFile } from "node:fs/promises";

async function loadController(name) {
  const source = (await readFile(new URL(`../../app/javascript/controllers/${name}_controller.js`, import.meta.url), "utf8"))
    .replace(/import \{ Controller \} from "@hotwired\/stimulus";?/, "class Controller {}");
  return (await import(`data:text/javascript;base64,${Buffer.from(source).toString("base64")}`)).default;
}
const LazyLoad = await loadController("lazy_load");
const Timeout = await loadController("turbo_frame_timeout");

function textNode() { return { textContent: "", className: "" }; }
function lazyController() {
  const instance = new LazyLoad();
  instance.urlValue = "/synthetic-connections";
  instance.failureMessageValue = "加载失败（%{status}）";
  instance.networkErrorMessageValue = "Réseau indisponible <synthetic>";
  instance.hasLoadingTarget = true;
  instance.hasFrameTarget = true;
  instance.loadingTarget = {
    children: [], classList: { add() {} },
    replaceChildren(...children) { this.children = children; },
    set innerHTML(_value) { throw new Error("Error copy must be inserted as text, not HTML"); },
  };
  instance.frameTarget = { innerHTML: "" };
  return instance;
}

globalThis.document = { querySelector() { return null; }, createElement() { return textNode(); } };

for (const message of ["超时", "Délai dépassé", '<img src=x onerror="synthetic">']) {
  test(`timeout uses translated text safely: ${message}`, () => {
    const instance = new Timeout();
    instance.messageValue = message;
    const paragraph = textNode();
    instance.element = { innerHTML: "", querySelector() { return paragraph; } };
    instance.handleTimeout();
    assert.equal(paragraph.textContent, message);
    assert.ok(!instance.element.innerHTML.includes(message));
    assert.ok(instance.element.innerHTML.includes("text-warning"));
  });
}

test("HTTP failures interpolate the actual status into localized text", async () => {
  const originalFetch = globalThis.fetch;
  const originalError = console.error;
  console.error = () => {};
  globalThis.fetch = async () => ({ ok: false, status: 503, statusText: "Synthetic" });
  try {
    const instance = lazyController();
    await instance.load();
    assert.equal(instance.loadingTarget.children[0]?.textContent, "加载失败（503）");
    assert.equal(instance.loading, false);
    assert.notEqual(instance.loadedValue, true);
  } finally { globalThis.fetch = originalFetch; console.error = originalError; }
});

test("network failure uses supplied translated text without interpreting markup", async () => {
  const originalFetch = globalThis.fetch;
  const originalError = console.error;
  console.error = () => {};
  globalThis.fetch = async () => { throw new Error("Synthetic failure"); };
  try {
    const instance = lazyController();
    await instance.load();
    assert.equal(instance.loadingTarget.children[0]?.textContent, instance.networkErrorMessageValue);
    assert.equal(instance.loadingTarget.children[0]?.className, "text-destructive text-sm");
    assert.equal(instance.loading, false);
  } finally { globalThis.fetch = originalFetch; console.error = originalError; }
});

test("successful lazy loading retains the existing response and loaded behavior", async () => {
  const originalFetch = globalThis.fetch;
  globalThis.fetch = async () => ({ ok: true, text: async () => "<p>Synthetic server response</p>" });
  try {
    const instance = lazyController();
    await instance.load();
    assert.equal(instance.frameTarget.innerHTML, "<p>Synthetic server response</p>");
    assert.equal(instance.loadedValue, true);
    assert.equal(instance.loading, false);
  } finally { globalThis.fetch = originalFetch; }
});
