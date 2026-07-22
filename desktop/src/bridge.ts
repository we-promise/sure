// Injected into the remote Sure page. Adds native-titlebar chrome and emits
// native-notification + badge events.
(() => {
  // Native titlebar chrome — a draggable top strip plus a top offset so the
  // logged-in app's sidebar logo clears the macOS traffic lights. Runs even
  // without the Tauri IPC API (drag regions are interpreted natively). Height
  // must match --titlebar-h in styles.css.
  if (!(window as any).__sureChrome) {
    (window as any).__sureChrome = true;
    const H = 38;
    const style = document.createElement("style");
    style.textContent =
      '[data-controller~="app-layout"]{padding-top:' + H + "px !important;box-sizing:border-box}" +
      ".__sure-drag{position:fixed;top:0;left:0;right:0;height:" + H +
      "px;z-index:2147483647;-webkit-app-region:drag}";
    (document.head || document.documentElement).appendChild(style);
    const addBar = () => {
      if (document.body && !document.querySelector(".__sure-drag")) {
        const bar = document.createElement("div");
        bar.className = "__sure-drag";
        bar.setAttribute("data-tauri-drag-region", "");
        document.body.appendChild(bar);
      }
    };
    if (document.body) addBar();
    else document.addEventListener("DOMContentLoaded", addBar);
  }

  const tauri = (window as any).__TAURI__;
  if (!tauri?.event) return;
  const emit = tauri.event.emit as (e: string, p: unknown) => void;

  // Menu wiring: registered here too because the main window may show the
  // remote Sure site (not the bundled main.ts document) when these fire.
  if (!(window as any).__sureMenuListeners) {
    (window as any).__sureMenuListeners = true;
    const show = async () => {
      const wins = await tauri.window.getAllWindows();
      const prefs = wins.find((w: any) => w.label === "prefs");
      if (prefs) { await prefs.show(); await prefs.setFocus(); }
    };
    tauri.event.listen("menu://preferences", show);
    tauri.event.listen("menu://switch-server", show);
    tauri.event.listen("active-server-changed", (e: any) =>
      window.location.assign(`${e.payload}/sessions/new`)
    );
  }

  // Sync-complete + alert toasts: Sure renders flash/notification nodes.
  const seen = new WeakSet<Element>();
  const scan = () => {
    document.querySelectorAll("[data-notification], .flash, [role='alert']").forEach((node) => {
      if (seen.has(node)) return;
      seen.add(node);
      const text = (node.textContent || "").trim();
      if (!text) return;
      emit("bridge://notify", { title: "Sure", body: text.slice(0, 180) });
    });
    // Dock badge: any element the page exposes with data-attention-count.
    const badgeEl = document.querySelector("[data-attention-count]");
    const count = badgeEl ? Number(badgeEl.getAttribute("data-attention-count")) : 0;
    emit("bridge://badge", { count: Number.isFinite(count) ? count : 0 });
  };

  const obs = new MutationObserver(() => scan());
  obs.observe(document.documentElement, { childList: true, subtree: true });
  scan();
})();
