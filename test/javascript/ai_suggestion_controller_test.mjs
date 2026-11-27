import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { test } from "node:test";
import vm from "node:vm";

const source = (await readFile(new URL("../../app/javascript/controllers/ai_suggestion_controller.js", import.meta.url), "utf8"))
  .replace(/^import .*;\n/m, "")
  .replace("export default class extends Controller", "globalThis.AiSuggestionController = class extends Controller");

// catchUp is async; let its fetch and json promises settle before asserting.
const settled = () => new Promise((resolve) => setImmediate(resolve));

function controller({ connected = true, status = "complete", fetchFails = false, url = "/show" } = {}) {
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

  const fetches = [];
  const fetch = async (requestUrl, options) => {
    fetches.push({ requestUrl, options });
    if (fetchFails) throw new Error("offline");
    return { ok: true, json: async () => ({ status }) };
  };

  const context = vm.createContext({ Controller: class {}, MutationObserver, fetch });
  vm.runInContext(source, context);

  const instance = new context.AiSuggestionController();
  instance.urlValue = url;
  const sourceTarget = {
    connected,
    hasAttribute(name) {
      return name === "connected" && this.connected;
    },
  };
  instance.sourceTarget = sourceTarget;
  instance.frameTarget = { src: null };
  instance.connect();

  return { instance, observers, sourceTarget, fetches };
}

test("an already-subscribed source navigates only when the answer is final", async () => {
  const { instance, fetches } = controller({ status: "complete" });
  await settled();

  assert.equal(fetches.length, 1);
  assert.equal(fetches[0].requestUrl, "/show");
  assert.equal(fetches[0].options.headers.Accept, "application/json");
  assert.equal(instance.frameTarget.src, "/show");
});

test("a pending answer leaves the waiting frame in place", async () => {
  const { instance } = controller({ status: "pending" });
  await settled();

  assert.equal(instance.frameTarget.src, null);
});

test("a failed probe leaves the waiting frame for the broadcast", async () => {
  const { instance } = controller({ fetchFails: true });
  await settled();

  assert.equal(instance.frameTarget.src, null);
});

test("a late subscription probes once after the connected mutation", async () => {
  const { instance, observers, sourceTarget, fetches } = controller({ connected: false });

  assert.equal(observers.length, 1);
  assert.deepEqual(Array.from(observers[0].options.attributeFilter), ["connected"]);
  assert.equal(fetches.length, 0);
  assert.equal(instance.frameTarget.src, null);

  sourceTarget.connected = true;
  observers[0].callback();
  await settled();

  assert.equal(fetches.length, 1);
  assert.equal(instance.frameTarget.src, "/show");
  assert.equal(observers[0].disconnected, true);
});

test("a reopened dialog always asks the server, with no sticky navigation flag", async () => {
  const first = controller({ status: "complete" });
  const second = controller({ status: "complete" });
  await settled();

  assert.equal(first.fetches.length, 1);
  assert.equal(second.fetches.length, 1);
  assert.equal(first.instance.frameTarget.src, "/show");
  assert.equal(second.instance.frameTarget.src, "/show");
});
