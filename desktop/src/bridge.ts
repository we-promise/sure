// Injected into every page loaded in the main window (local onboarding + the
// remote Sure site). Adds native-titlebar chrome, drags the window, forwards
// notifications/badge to Rust, intercepts SSO into the system browser, and
// navigates on server switches.
(() => {
  const tauri = (window as any).__TAURI__;

  // Diagnostics — visible in DevTools console. On the remote Sure page, IPC only
  // works if withGlobalTauri is set AND a capability's remote.urls matches.
  // eslint-disable-next-line no-console
  console.log("[sure] bridge loaded", {
    href: location.href,
    hasTauri: !!tauri,
    hasEvent: !!tauri?.event,
    hasCore: !!tauri?.core,
    hasWindow: !!tauri?.window,
  });

  // Native titlebar chrome — a draggable top strip plus a top offset so the
  // logged-in app's sidebar logo clears the macOS traffic lights. The strip
  // both carries data-tauri-drag-region (native) and calls startDragging on
  // mousedown (works whenever IPC is granted), so at least one path drags.
  if (!(window as any).__sureChrome) {
    (window as any).__sureChrome = true;
    const style = document.createElement("style");
    style.textContent =
      'nav[class~="w-[84px]"]{padding-top:44px !important;box-sizing:border-box}' +
      ".__sure-drag{position:fixed;top:0;left:0;right:0;height:34px;z-index:5;-webkit-app-region:drag}";
    (document.head || document.documentElement).appendChild(style);
    const addBar = () => {
      if (document.body && !document.querySelector(".__sure-drag")) {
        const bar = document.createElement("div");
        bar.className = "__sure-drag";
        bar.setAttribute("data-tauri-drag-region", "");
        bar.addEventListener("mousedown", (ev) => {
          if ((ev as MouseEvent).button !== 0) return;
          try {
            tauri?.window?.getCurrentWindow?.().startDragging?.();
          } catch {
            /* ignore — data-tauri-drag-region is the fallback */
          }
        });
        document.body.appendChild(bar);
      }
    };
    if (document.body) addBar();
    else document.addEventListener("DOMContentLoaded", addBar);
  }

  if (!tauri?.event) {
    // eslint-disable-next-line no-console
    console.warn("[sure] Tauri IPC unavailable on this page — notifications, SSO, and drag-by-API disabled");
    return;
  }
  const emit = tauri.event.emit as (e: string, p: unknown) => void;

  // SSO must run in the system browser (passkeys/WebAuthn don't work in an
  // embedded webview). Each provider is a form POSTing to /auth/{provider};
  // intercept and hand off to Rust, which opens the browser. Password login
  // (POST /sessions) is untouched.
  if (!(window as any).__sureSsoHook) {
    (window as any).__sureSsoHook = true;
    document.addEventListener(
      "submit",
      (ev) => {
        const form = ev.target as HTMLFormElement | null;
        if (!form || form.tagName !== "FORM") return;
        let path: string;
        try {
          path = new URL(form.action, location.href).pathname;
        } catch {
          return;
        }
        const m = path.match(/^\/auth\/([A-Za-z0-9_-]+)$/);
        if (!m) return; // not an SSO provider form (e.g. /sessions, /auth/x/callback)
        ev.preventDefault();
        ev.stopImmediatePropagation();
        // eslint-disable-next-line no-console
        console.log("[sure] SSO intercept -> start_sso", m[1]);
        Promise.resolve(tauri.core?.invoke("start_sso", { server: location.origin, provider: m[1] }))
          // eslint-disable-next-line no-console
          .then(() => console.log("[sure] start_sso ok"))
          // eslint-disable-next-line no-console
          .catch((e: unknown) => console.error("[sure] start_sso failed", e));
      },
      true // capture, to beat any page handlers
    );
  }

  // Navigate the main window when the active server changes (e.g. switching
  // servers from the Preferences window while logged in).
  if (!(window as any).__sureNavListener) {
    (window as any).__sureNavListener = true;
    tauri.event.listen("active-server-changed", (e: any) => {
      const w = window as any;
      if (w.__sureNav) return;
      w.__sureNav = e.payload;
      window.location.assign(`${e.payload}/`);
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
