import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import vm from "node:vm";
import ts from "typescript";

const source = readFileSync(new URL("../src/bridge.ts", import.meta.url), "utf8");
const script = new vm.Script(
  ts.transpileModule(source, { compilerOptions: { target: ts.ScriptTarget.ES2021 } }).outputText
);

function loadBridge(pageUrl = "https://sure.example/reports") {
  const listeners = new Map();
  const context = vm.createContext({
    URL,
    window: {},
    location: new URL(pageUrl),
    console: { log() {}, warn() {} },
    document: {
      head: { appendChild() {} },
      createElement: () => ({}),
      addEventListener(type, listener, capture) {
        const entries = listeners.get(type) || [];
        entries.push({ listener, capture });
        listeners.set(type, entries);
      },
    },
  });
  script.runInContext(context);

  return {
    reinject: () => script.runInContext(context),
    listeners,
    click(target) {
      const event = {
        target,
        defaultPrevented: false,
        propagationStopped: false,
        preventDefault() { this.defaultPrevented = true; },
        stopImmediatePropagation() { this.propagationStopped = true; },
      };
      for (const { listener, capture } of listeners.get("click") || []) {
        assert.equal(capture, true, "the export link must be prepared before Turbo handles the click");
        listener(event);
      }
      return event;
    },
  };
}

function anchor(href, attributes = {}) {
  const values = { href, ...attributes };
  const link = {
    href,
    attributes: values,
    hasAttribute: (name) => Object.hasOwn(values, name),
    setAttribute: (name, value) => { values[name] = value; },
    closest: (selector) => {
      assert.equal(selector, "a[href]");
      return link;
    },
  };
  return link;
}

function nestedTarget(link) {
  return {
    closest(selector) {
      assert.equal(selector, "a[href]");
      return link;
    },
  };
}

test("CSV clicks select native download without cancelling the authenticated request", () => {
  const bridge = loadBridge();
  const href = "/reports/export_transactions.csv?period_type=custom&start_date=2026-09-01&end_date=2026-09-09";
  const link = anchor(href, { target: "_blank" });

  const event = bridge.click(nestedTarget(link));

  assert.deepEqual(link.attributes, {
    href,
    target: "_self",
    download: "",
    "data-turbo": "false",
  });
  assert.equal(link.href, href, "the export URL and date filters must stay unchanged");
  assert.equal(event.defaultPrevented, false);
  assert.equal(event.propagationStopped, false);
});

test("CSV downloads support a server mounted beneath a path prefix", () => {
  const bridge = loadBridge("https://sure.example/finance/sure/reports");
  const link = anchor("https://sure.example/finance/sure/reports/export_transactions.csv?period_type=ytd");

  bridge.click(link);

  assert.equal(link.attributes.download, "");
  assert.equal(link.attributes.target, "_self");
});

test("an explicit filename is retained when marking a report download", () => {
  const bridge = loadBridge();
  const link = anchor("/reports/export_transactions.csv", { download: "report.csv" });

  bridge.click(nestedTarget(link));

  assert.equal(link.attributes.download, "report.csv");
});

test("other origins, routes and formats are left unchanged", () => {
  const bridge = loadBridge();
  for (const href of [
    "https://other.example/reports/export_transactions.csv",
    "http://sure.example/reports/export_transactions.csv",
    "https://sure.example:8443/reports/export_transactions.csv",
    "/reports/print",
    "/reports/export_transactions.pdf",
    "/reports/export_transactions.csv/preview",
    "/other.csv",
    "http://[invalid",
  ]) {
    const link = anchor(href, { target: "_blank" });

    bridge.click(nestedTarget(link));

    assert.deepEqual(link.attributes, { href, target: "_blank" }, href);
  }
});

test("clicks outside links remain unaffected", () => {
  const bridge = loadBridge();
  assert.doesNotThrow(() => bridge.click(nestedTarget(null)));
  assert.doesNotThrow(() => bridge.click({}));
  assert.doesNotThrow(() => bridge.click(null));
});

test("reinjection installs only one report download listener, even without Tauri IPC", () => {
  const bridge = loadBridge();
  bridge.reinject();

  assert.equal(bridge.listeners.get("click").length, 1);
  const link = anchor("/reports/export_transactions.csv");
  bridge.click(nestedTarget(link));
  assert.equal(link.attributes.download, "");
});
