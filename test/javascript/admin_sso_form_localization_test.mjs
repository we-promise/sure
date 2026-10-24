import assert from "node:assert/strict";
import { test } from "node:test";
import { readFile } from "node:fs/promises";

const source = (await readFile(new URL("../../app/javascript/controllers/admin_sso_form_controller.js", import.meta.url), "utf8"))
  .replace(/import \{ Controller \} from "@hotwired\/stimulus";?/, "class Controller {}");
const SsoForm = (await import(`data:text/javascript;base64,${Buffer.from(source).toString("base64")}`)).default;
const messages = {
  copied: "已复制！", copy_failed: "无法复制到剪贴板", issuer_valid: "OIDC 签发者有效",
  issuer_mismatch_trailing: "签发者不匹配：发现文档返回 %{issuer}。请保留末尾斜杠。",
  issuer_mismatch: "签发者不匹配：发现文档返回 %{issuer}。请原样复制。",
  browser_validation_unavailable: "浏览器无法验证（CORS）。仍可保存提供商。",
  testing: "正在测试…", request_failed: "请求失败：%{message}", test_connection: "测试连接"
};
function node() {
  return { textContent: "", className: "", classList: { add() {}, remove() {} }, remove() {},
    set innerHTML(_) { throw new Error("Dynamic feedback must remain text"); } };
}
function instance() { const result = new SsoForm(); result.messagesValue = messages; return result; }
function issuerInput(value) {
  return { value, classList: { add() {}, remove() {} }, parentElement: {
    messages: [], querySelector() { return null; }, appendChild(value) { this.messages.push(value); }
  } };
}
async function isolated(callback) {
  const previous = { fetch: globalThis.fetch, document: globalThis.document, setTimeout: globalThis.setTimeout,
    alert: globalThis.alert, navigator: Object.getOwnPropertyDescriptor(globalThis, "navigator"), error: console.error };
  const timers = [];
  globalThis.document = { createElement: node, querySelector() { return { content: "synthetic-csrf" }; } };
  globalThis.setTimeout = (callback, delay) => { callback.delay = delay; timers.push(callback); return timers.length; };
  globalThis.fetch = async () => { throw new Error("Unexpected synthetic network call"); };
  console.error = () => {};
  globalThis.alert = () => {};
  try { await callback(timers); } finally {
    globalThis.fetch = previous.fetch; globalThis.document = previous.document;
    globalThis.setTimeout = previous.setTimeout; globalThis.alert = previous.alert; console.error = previous.error;
    if (previous.navigator) Object.defineProperty(globalThis, "navigator", previous.navigator);
    else delete globalThis.navigator;
  }
}

for (const method of ["copyCallback", "copySamlCallback"]) {
  test(`${method} copies the exact callback and safely localizes feedback`, () => isolated(async (timers) => {
    let copied;
    Object.defineProperty(globalThis, "navigator", { configurable: true, value: { clipboard: { writeText: async (value) => { copied = value; } } } });
    const controller = instance();
    controller.callbackUrlTarget = { textContent: "https://example.invalid/auth/Synthetic/callback" };
    controller.samlCallbackUrlTarget = controller.callbackUrlTarget;
    controller.hasSamlCallbackUrlTarget = true;
    const button = { textContent: "", classList: { add() {}, remove() {} } };
    Object.defineProperty(button, "innerHTML", { get() { return "<span>Original copy icon</span>"; }, set(value) { assert.equal(value, "<span>Original copy icon</span>"); } });
    controller.messagesValue = { ...messages, copied: '<img src=x onerror="synthetic"> 已复制' };
    const event = { preventDefault() {}, currentTarget: button };
    controller[method](event);
    event.currentTarget = null; // A real DOM event releases currentTarget after dispatch.
    await new Promise(setImmediate);
    assert.equal(copied, controller.callbackUrlTarget.textContent);
    assert.equal(button.textContent, controller.messagesValue.copied);
    assert.equal(timers.length, 1);
    assert.equal(timers[0].delay, 2000);
    timers[0]();
  }));
  test(`${method} localizes clipboard failure`, () => isolated(async () => {
    Object.defineProperty(globalThis, "navigator", { configurable: true, value: { clipboard: { writeText: async () => { throw new Error("Synthetic clipboard failure"); } } } });
    const controller = instance(); controller.callbackUrlTarget = { textContent: "https://example.invalid/callback" };
    controller.samlCallbackUrlTarget = controller.callbackUrlTarget; controller.hasSamlCallbackUrlTarget = true;
    let alertText; globalThis.alert = (value) => { alertText = value; };
    controller[method]({ preventDefault() {}, currentTarget: node() });
    await new Promise(setImmediate);
    assert.equal(alertText, messages.copy_failed);
  }));
}

for (const [returned, key] of [
  ["https://example.invalid", "issuer_valid"],
  ["https://example.invalid/", "issuer_mismatch_trailing"],
  ['https://other.invalid/<img onerror="synthetic">$&', "issuer_mismatch"]
]) {
  test(`OIDC discovery uses localized ${key} as text and keeps the request contract`, () => isolated(async () => {
    const controller = instance(); const input = issuerInput("  https://example.invalid  ");
    let request;
    globalThis.fetch = async (...args) => { request = args; return { ok: true, json: async () => ({ issuer: returned }) }; };
    await controller.validateIssuer({ target: input });
    assert.deepEqual(request, ["https://example.invalid/.well-known/openid-configuration", { method: "GET", headers: { Accept: "application/json" } }]);
    assert.equal(input.parentElement.messages[0].textContent, messages[key].replace("%{issuer}", () => returned));
    assert.equal(input.value, "  https://example.invalid  ");
  }));
}
test("browser discovery failure remains a localized warning and does not save the provider", () => isolated(async () => {
  const controller = instance(); const input = issuerInput("https://example.invalid");
  let requests = 0; globalThis.fetch = async () => { requests++; throw new Error("Synthetic CORS failure"); };
  await controller.validateIssuer({ target: input });
  assert.equal(requests, 1);
  assert.equal(input.parentElement.messages[0].textContent, messages.browser_validation_unavailable);
}));
test("empty issuer and missing test URL cause no requests", () => isolated(async () => {
  let requests = 0; globalThis.fetch = async () => { requests++; };
  const controller = instance(); controller.testResultTarget = node();
  await controller.validateIssuer({ target: issuerInput("  ") });
  await controller.testConnection({ currentTarget: { dataset: {} } });
  assert.equal(requests, 0);
}));
for (const success of [true, false]) {
  test(`test connection preserves server status ${success}, POST and CSRF`, () => isolated(async () => {
    const controller = instance(); controller.testResultTarget = node();
    const button = { dataset: { adminSsoFormTestUrlValue: "/synthetic-sso/test" }, textContent: "", disabled: false };
    globalThis.fetch = async (url, options) => {
      assert.equal(button.disabled, true); assert.equal(button.textContent, messages.testing);
      assert.equal(url, "/synthetic-sso/test");
      assert.deepEqual(options, { method: "POST", headers: { "Content-Type": "application/json", "X-CSRF-Token": "synthetic-csrf" } });
      return { json: async () => ({ success, message: '<img src=x onerror="synthetic"> original response' }) };
    };
    await controller.testConnection({ currentTarget: button });
    assert.equal(controller.testResultTarget.textContent, `${success ? "✓" : "✗"} <img src=x onerror="synthetic"> original response`);
    assert.equal(button.disabled, false); assert.equal(button.textContent, messages.test_connection);
  }));
}
test("request errors safely interpolate literal text and restore the localized button", () => isolated(async () => {
  const controller = instance(); controller.testResultTarget = node();
  const button = { dataset: { adminSsoFormTestUrlValue: "/synthetic-sso/test" }, textContent: "", disabled: false };
  const detail = '<img src=x onerror="synthetic"> $& %{issuer}';
  globalThis.fetch = async () => { throw new Error(detail); };
  await controller.testConnection({ currentTarget: button });
  assert.equal(controller.testResultTarget.textContent, `✗ ${messages.request_failed.replace("%{message}", () => detail)}`);
  assert.equal(button.textContent, messages.test_connection); assert.equal(button.disabled, false);
}));
