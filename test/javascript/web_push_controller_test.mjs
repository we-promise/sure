import assert from "node:assert/strict";
import { webcrypto } from "node:crypto";
import { readFile } from "node:fs/promises";
import { test } from "node:test";
import vm from "node:vm";

const source = (await readFile(new URL("../../app/javascript/controllers/web_push_controller.js", import.meta.url), "utf8"))
  .replace(/^import .*;\n/m, "")
  .replace("export default class extends Controller", "globalThis.WebPushController = class extends Controller");

async function controller({ endpoint, registrations, subscriptionKey = [1, 2, 3], unsubscribeSucceeds = true }) {
  const calls = { permission: 0, subscribe: 0, fetch: 0, unsubscribe: 0 };
  const posts = [];
  const timers = new Map();
  let nextTimer = 0;
  const makeSubscription = (url, key) => ({
    endpoint: url,
    options: { applicationServerKey: Uint8Array.from(key).buffer },
    toJSON: () => ({ endpoint: url, keys: { p256dh: "public-key", auth: "secret" } }),
    unsubscribe: async () => {
      calls.unsubscribe++;
      if (unsubscribeSucceeds) current = null;
      return unsubscribeSucceeds;
    },
  });
  let current = makeSubscription(endpoint, subscriptionKey);
  const registration = { pushManager: {
    getSubscription: async () => current,
    subscribe: async (options) => {
      calls.subscribe++;
      current = makeSubscription(`${endpoint}-rotated`, options.applicationServerKey);
      return current;
    },
  } };
  const context = vm.createContext({
    Controller: class {},
    window: { isSecureContext: true, PushManager: class {}, Notification: {}, matchMedia: () => ({ matches: false }) },
    navigator: { userAgent: "Desktop", platform: "Linux", maxTouchPoints: 0, serviceWorker: {
      getRegistration: async () => registration,
      ready: Promise.resolve(registration),
    } },
    Notification: { permission: "granted", requestPermission: () => { calls.permission++; } },
    crypto: webcrypto,
    TextEncoder,
    Uint8Array,
    atob,
    clearTimeout: (id) => timers.delete(id),
    setTimeout: (callback) => { const id = ++nextTimer; timers.set(id, callback); return id; },
    document: { querySelector: () => ({ content: "csrf-token" }) },
    fetch: async (_url, options) => {
      calls.fetch++;
      if (options.method === "POST" && options.body) posts.push(JSON.parse(options.body));
      return { status: options.method === "DELETE" ? 204 : 201, ok: true, json: async () => ({ id: "new-id" }) };
    },
  });
  vm.runInContext(source, context);
  const instance = new context.WebPushController();
  instance.publicKeyValue = "AQID";
  instance.registrationsValue = registrations;
  instance.subscriptionIdValue = Object.keys(registrations)[0] || "";
  instance.urlValue = "/web_push_subscriptions";
  instance.messagesValue = { accepted: "accepted", pending: "pending", enabled: "enabled", disabled: "disabled", request: "Localized retry guidance" };
  instance.iosGuidanceTarget = { classList: { toggle() {} } };
  instance.statusTarget = {};
  instance.enableTarget = {};
  instance.disableTarget = {};
  instance.testTarget = {};
  await instance.connect();
  return { instance, calls, posts, timers, context };
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
  assert.deepEqual(calls, { permission: 0, subscribe: 0, fetch: 0, unsubscribe: 0 });
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
  await instance.run(async () => { throw new Error("Native browser error with internal details"); });
  assert.equal(instance.statusTarget.textContent, "Localized retry guidance");
});

test("enable replaces an old VAPID subscription when its server registration is gone", async () => {
  const { instance, calls, posts } = await controller({ endpoint: "https://fcm.googleapis.com/old", registrations: {}, subscriptionKey: [9, 8, 7] });
  await instance.enable();
  assert.equal(calls.unsubscribe, 1);
  assert.equal(calls.subscribe, 1);
  assert.equal(posts[0].endpoint, "https://fcm.googleapis.com/old-rotated");
  assert.equal(instance.statusTarget.textContent, "enabled");
});

test("a registered endpoint with an old VAPID key is not advertised as enabled", async () => {
  const endpoint = "https://fcm.googleapis.com/old";
  const { instance, calls } = await controller({ endpoint, registrations: { "old-id": await digest(endpoint) }, subscriptionKey: [9, 8, 7] });
  assert.equal(instance.statusTarget.textContent, "disabled");
  assert.equal(instance.enableTarget.disabled, false);
  assert.equal(instance.testTarget.disabled, true);
  assert.equal(calls.unsubscribe, 0);
  await instance.enable();
  assert.equal(calls.unsubscribe, 1);
  assert.equal(calls.subscribe, 1);
  assert.equal(calls.fetch, 2);
});

test("enable reuses a browser subscription already bound to the current VAPID key", async () => {
  const { instance, calls, posts } = await controller({ endpoint: "https://fcm.googleapis.com/current", registrations: {} });
  await instance.enable();
  assert.equal(calls.unsubscribe, 0);
  assert.equal(calls.subscribe, 0);
  assert.equal(posts[0].endpoint, "https://fcm.googleapis.com/current");
});

test("failed old-key unsubscription does not register or report a working replacement", async () => {
  const { instance, calls } = await controller({ endpoint: "https://fcm.googleapis.com/old", registrations: {}, subscriptionKey: [9, 8, 7], unsubscribeSucceeds: false });
  await instance.enable();
  assert.equal(calls.fetch, 0);
  assert.equal(calls.subscribe, 0);
  assert.equal(instance.statusTarget.textContent, "Localized retry guidance");
});

function deferred() {
  let resolve;
  let reject;
  const promise = new Promise((yes, no) => { resolve = yes; reject = no; });
  return { promise, resolve, reject };
}

test("disable invalidates a poll already awaiting a provider result", async () => {
  const endpoint = "https://fcm.googleapis.com/local";
  const { instance, timers } = await controller({ endpoint, registrations: { "local-id": await digest(endpoint) } });
  const response = deferred();
  instance.request = (_url, method) => method === "GET" ? response.promise : Promise.resolve({});
  const polling = instance.pollTest();
  await instance.disable();
  response.resolve({ test_status: "accepted" });
  await polling;
  assert.equal(instance.statusTarget.textContent, "disabled");
  assert.equal(timers.size, 0);
});

test("a new failed Test cancels the earlier timer and ignores its in-flight result", async () => {
  const endpoint = "https://fcm.googleapis.com/local";
  const { instance, timers } = await controller({ endpoint, registrations: { "local-id": await digest(endpoint) } });
  instance.messagesValue.queued = "queued";
  await instance.test();
  assert.equal(timers.size, 1);
  const response = deferred();
  instance.request = (_url, method) => {
    if (method === "GET") return response.promise;
    return Promise.reject(Object.assign(new Error("429"), { userMessage: "Too many tests" }));
  };
  const polling = instance.pollTest();
  await instance.test();
  response.resolve({ test_status: "pending" });
  await polling;
  assert.equal(instance.statusTarget.textContent, "Too many tests");
  assert.equal(timers.size, 0);
});

test("disconnect invalidates late poll errors", async () => {
  const { instance, timers } = await controller({ endpoint: "https://fcm.googleapis.com/local", registrations: {} });
  const response = deferred();
  instance.request = () => response.promise;
  const polling = instance.pollTest();
  instance.disconnect();
  response.reject(new Error("Network failed"));
  await polling;
  assert.equal(instance.statusTarget.textContent, "disabled");
  assert.equal(timers.size, 0);
});

test("a superseded poll 404 cannot remove a replacement registration", async () => {
  const endpoint = "https://fcm.googleapis.com/local";
  const { instance, context } = await controller({ endpoint, registrations: { "local-id": await digest(endpoint) } });
  const response = deferred();
  const originalFetch = context.fetch;
  context.fetch = (url, options) => options.method === "GET" ? response.promise : originalFetch(url, options);
  const polling = instance.pollTest();
  await instance.disable();
  await instance.enable();
  response.resolve({ status: 404, ok: false, json: async () => ({}) });
  await polling;
  assert.equal(instance.subscriptionIdValue, "new-id");
  assert.equal(instance.statusTarget.textContent, "enabled");
  assert.equal(instance.testTarget.disabled, false);
});

test("reconnecting the same controller does not revive a previous connection's poll", async () => {
  const endpoint = "https://fcm.googleapis.com/local";
  const { instance } = await controller({ endpoint, registrations: { "local-id": await digest(endpoint) } });
  const response = deferred();
  instance.request = () => response.promise;
  const polling = instance.pollTest();
  instance.disconnect();
  await instance.connect();
  response.resolve({ test_status: "accepted" });
  await polling;
  assert.equal(instance.statusTarget.textContent, "enabled");
});

for (const status of [202, 404]) {
  test(`a Test POST completing with ${status} after reconnect cannot change the new lifecycle`, async () => {
    const endpoint = "https://fcm.googleapis.com/local";
    const { instance, context, timers } = await controller({ endpoint, registrations: { "local-id": await digest(endpoint) } });
    instance.messagesValue.queued = "queued";
    const response = deferred();
    context.fetch = () => response.promise;
    const testing = instance.test();
    instance.disconnect();
    await instance.connect();
    instance.busy = true;
    instance.updateControls();
    response.resolve({ status, ok: status === 202, json: async () => ({}) });
    await testing;
    assert.equal(instance.statusTarget.textContent, "enabled");
    assert.equal(instance.subscriptionIdValue, "local-id");
    assert.equal(instance.busy, true);
    assert.equal(instance.testTarget.disabled, true);
    assert.equal(timers.size, 0);
  });
}

for (const action of ["enable", "disable"]) {
  test(`an old ${action} continuation cannot overwrite a reconnected controller`, async () => {
    const endpoint = "https://fcm.googleapis.com/local";
    const registrations = action === "disable" ? { "local-id": await digest(endpoint) } : {};
    const { instance } = await controller({ endpoint, registrations });
    const entered = deferred();
    const response = deferred();
    instance.request = () => { entered.resolve(); return response.promise; };
    const operation = instance[action]();
    await entered.promise;
    instance.disconnect();
    await instance.connect();
    const expectedStatus = instance.statusTarget.textContent;
    const expectedId = instance.subscriptionIdValue;
    response.resolve({ id: "old-operation-id" });
    await operation;
    assert.equal(instance.statusTarget.textContent, expectedStatus);
    assert.equal(instance.subscriptionIdValue, expectedId);
  });
}
