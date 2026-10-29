import assert from "node:assert/strict";
import { webcrypto } from "node:crypto";
import { readFile } from "node:fs/promises";
import { test } from "node:test";
import vm from "node:vm";

const source = (await readFile(new URL("../../app/javascript/controllers/web_push_controller.js", import.meta.url), "utf8"))
  .replace(/^import .*;\n/m, "")
  .replace("export default class extends Controller", "globalThis.WebPushController = class extends Controller");

async function controller({ endpoint, registrations }) {
  const calls = { permission: 0, subscribe: 0, fetch: 0 };
  const subscription = { endpoint };
  const registration = { pushManager: { getSubscription: async () => subscription } };
  const context = vm.createContext({
    Controller: class {},
    window: { isSecureContext: true, PushManager: class {}, Notification: {}, matchMedia: () => ({ matches: false }) },
    navigator: { userAgent: "Desktop", platform: "Linux", maxTouchPoints: 0, serviceWorker: {
      getRegistration: async () => registration,
    } },
    Notification: { permission: "granted", requestPermission: () => { calls.permission++; } },
    crypto: webcrypto,
    TextEncoder,
    clearTimeout,
    fetch: () => { calls.fetch++; },
  });
  vm.runInContext(source, context);
  const instance = new context.WebPushController();
  instance.publicKeyValue = "configured";
  instance.registrationsValue = registrations;
  // A stale rendered ID must not be treated as proof of the local subscription.
  instance.subscriptionIdValue = Object.keys(registrations)[0] || "";
  instance.messagesValue = { enabled: "enabled", disabled: "disabled" };
  instance.iosGuidanceTarget = { classList: { toggle() {} } };
  instance.statusTarget = {};
  instance.enableTarget = {};
  instance.disableTarget = {};
  instance.testTarget = {};
  await instance.connect();
  return { instance, calls };
}

async function digest(endpoint) {
  return Buffer.from(await webcrypto.subtle.digest("SHA-256", new TextEncoder().encode(endpoint))).toString("hex");
}

test("a rotated endpoint cannot test or disable an unrelated server registration", async () => {
  const { instance, calls } = await controller({ endpoint: "https://fcm.googleapis.com/new", registrations: {
    "old-id": await digest("https://fcm.googleapis.com/old"),
  } });
  assert.equal(instance.subscriptionIdValue, "");
  assert.equal(instance.enableTarget.disabled, false);
  assert.equal(instance.disableTarget.disabled, true);
  assert.equal(instance.testTarget.disabled, true);
  assert.equal(instance.statusTarget.textContent, "disabled");
  assert.deepEqual(calls, { permission: 0, subscribe: 0, fetch: 0 });
});

test("the local endpoint matches its own record rather than the newest session record", async () => {
  const endpoint = "https://fcm.googleapis.com/local";
  const { instance } = await controller({ endpoint, registrations: {
    "newest-other-id": await digest("https://fcm.googleapis.com/other"),
    "local-id": await digest(endpoint),
  } });
  assert.equal(instance.subscriptionIdValue, "local-id");
  assert.equal(instance.enableTarget.disabled, true);
  assert.equal(instance.testTarget.disabled, false);
  assert.equal(instance.disableTarget.disabled, false);
  assert.equal(instance.statusTarget.textContent, "enabled");
});

test("native browser failures display localized guidance without raw exception details", async () => {
  const { instance } = await controller({ endpoint: "https://fcm.googleapis.com/local", registrations: {} });
  instance.messagesValue.request = "Localized retry guidance";
  await instance.run(async () => { throw new Error("Native browser error with internal details"); });
  assert.equal(instance.statusTarget.textContent, "Localized retry guidance");
});
