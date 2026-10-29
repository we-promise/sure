import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { test } from "node:test";
import vm from "node:vm";

const source = await readFile(
  new URL("../../app/views/pwa/service-worker.js", import.meta.url),
  "utf8",
);

function worker() {
  const handlers = new Map();
  const shown = [];
  const opened = [];
  const self = {
    location: { origin: "https://sure.example" },
    addEventListener: (name, handler) => handlers.set(name, handler),
    registration: {
      showNotification: async (title, options) => shown.push({ title, options }),
    },
    clients: {
      matchAll: async () => [],
      openWindow: async (url) => opened.push(url),
    },
  };
  vm.runInNewContext(source, { self, URL });
  return { handlers, shown, opened };
}

async function dispatch(worker, name, event) {
  const handler = worker.handlers.get(name);
  assert.equal(typeof handler, "function", `${name} handler must be registered`);
  let completion;
  handler({ ...event, waitUntil: (promise) => { completion = promise; } });
  assert.equal(typeof completion?.then, "function", `${name} must keep the worker alive`);
  await completion;
}

test("a push visibly displays its generic server-localized message", async () => {
  const state = worker();
  const path = "/insights#insight_123e4567-e89b-12d3-a456-426614174000";
  await dispatch(state, "push", {
    data: { json: () => ({ title: "Sure", body: "A new financial alert is available.", data: { path } }) },
  });
  assert.equal(state.shown.length, 1);
  assert.equal(state.shown[0].title, "Sure");
  assert.equal(state.shown[0].options.body, "A new financial alert is available.");
  assert.equal(state.shown[0].options.data.path, path);
});

test("an empty or malformed push still displays a visible notification", async () => {
  for (const data of [undefined, { json: () => { throw new SyntaxError("bad payload"); } }]) {
    const state = worker();
    await dispatch(state, "push", { data });
    assert.equal(state.shown.length, 1);
    assert.equal(state.shown[0].title, "Sure");
  }
});

test("notification clicks only open the same-origin insights page", async () => {
  for (const path of ["https://evil.example/insights", "//evil.example/insights", "/accounts", "javascript:alert(1)", undefined]) {
    const state = worker();
    let closed = false;
    await dispatch(state, "notificationclick", {
      notification: { data: { path }, close: () => { closed = true; } },
    });
    assert.equal(closed, true);
    assert.equal(state.opened.length, 1);
    const destination = new URL(state.opened[0], "https://sure.example");
    assert.equal(destination.origin, "https://sure.example");
    assert.equal(destination.pathname, "/insights");
  }
});

test("notification clicks retain the valid insight anchor", async () => {
  const state = worker();
  const path = "/insights#insight_123e4567-e89b-12d3-a456-426614174000";
  await dispatch(state, "notificationclick", {
    notification: { data: { path }, close: () => {} },
  });
  assert.equal(new URL(state.opened[0], "https://sure.example").hash,
    "#insight_123e4567-e89b-12d3-a456-426614174000");
});
