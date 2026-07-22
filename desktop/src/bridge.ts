// Injected into the remote Sure page. Adds native-titlebar chrome and emits
// native-notification + badge events.
(() => {
  // Native titlebar chrome — a draggable top strip plus a top offset so the
  // logged-in app's sidebar logo clears the macOS traffic lights. Runs even
  // without the Tauri IPC API (drag regions are interpreted natively). Height
  // must match --titlebar-h in styles.css.
  if (!(window as any).__sureChrome) {
    (window as any).__sureChrome = true;
    const style = document.createElement("style");
    style.textContent =
      // Offset ONLY the left icon rail (the 84px column holding the logomark),
      // so its logo clears the macOS traffic lights. Main content stays full-height.
      'nav[class~="w-[84px]"]{padding-top:44px !important;box-sizing:border-box}' +
      // Draggable top strip. z-index sits below Sure's sticky headers/overlays
      // (which use z-10+), so empty top areas drag the window while Sure's own
      // controls stay clickable.
      ".__sure-drag{position:fixed;top:0;left:0;right:0;height:34px;z-index:5;-webkit-app-region:drag}";
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
    tauri.event.listen("active-server-changed", (e: any) => {
      // De-dupe: only the first navigation request for a server wins, so a
      // single connect never fires multiple concurrent GET /sessions/new
      // (which would race the session cookie against the form's CSRF token).
      const w = window as any;
      if (w.__sureNav) return;
      w.__sureNav = e.payload;
      window.location.assign(`${e.payload}/sessions/new`);
    });
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
