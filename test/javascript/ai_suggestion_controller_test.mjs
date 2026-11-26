import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { test } from "node:test";
import vm from "node:vm";

const source = (await readFile(new URL("../../app/javascript/controllers/ai_suggestion_controller.js", import.meta.url), "utf8"))
  .replace(/^import .*;\n/m, "")
  .replace("export default class extends Controller", "globalThis.AiSuggestionController = class extends Controller");

function controller({ connected = true, storage = new Map(), url = "/show", key = "suggestion:1" } = {}) {
  const observers = [];
  class MutationObserver {
    constructor(callback) {
      this.callback = callback;
      this.disconnected = false;
      observers.push(this);
    }

    observe(target, options) {
      this.target = target;
      this.options = options;
    }

    disconnect() {
      this.disconnected = true;
    }
  }

  const sessionStorage = {
    getItem: (name) => storage.get(name) ?? null,
    setItem: (name, value) => storage.set(name, value),
  };
  const context = vm.createContext({ Controller: class {}, MutationObserver, sessionStorage });
  vm.runInContext(source, context);

  const instance = new context.AiSuggestionController();
  instance.urlValue = url;
  instance.keyValue = key;
  const sourceTarget = {
    connected,
    hasAttribute(name) {
      return name === "connected" && this.connected;
    },
  };
  instance.sourceTarget = sourceTarget;
  instance.frameTarget = { src: null };
  instance.connect();

  return { instance, observers, sourceTarget, storage };
}

test("an already-subscribed source navigates the waiting frame to show", () => {
  const { instance, storage } = controller();

  assert.equal(instance.frameTarget.src, "/show");
  assert.equal(storage.get("suggestion:1"), "1");
});

test("a late subscription navigates once after the connected mutation", () => {
  const { instance, observers, sourceTarget } = controller({ connected: false });

  assert.equal(observers.length, 1);
  assert.deepEqual(Array.from(observers[0].options.attributeFilter), ["connected"]);
  assert.equal(instance.frameTarget.src, null);

  sourceTarget.connected = true;
  observers[0].callback();

  assert.equal(instance.frameTarget.src, "/show");
  assert.equal(observers[0].disconnected, true);
});

test("the one-shot flag survives a new controller after the frame loads a pending result", () => {
  const storage = new Map([ [ "suggestion:1", "1" ] ]);
  const { instance, observers } = controller({ storage });

  assert.equal(instance.frameTarget.src, null);
  assert.equal(observers.length, 0);
});
