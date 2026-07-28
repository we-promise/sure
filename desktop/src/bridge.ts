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

  // Native titlebar chrome — offset the left icon rail so its logo clears the
  // traffic lights, and make the top ~34px band drag the window. Using a
  // document-level mousedown (rather than a fixed overlay strip) means dragging
  // works on every page regardless of Sure's own sticky headers, while its
  // interactive controls in that band stay clickable. Main content is not
  // pushed down.
  if (!(window as any).__sureChrome) {
    (window as any).__sureChrome = true;
    const style = document.createElement("style");
    style.textContent = 'nav[class~="w-[84px]"]{padding-top:44px !important;box-sizing:border-box}';
    (document.head || document.documentElement).appendChild(style);

    const DRAG_H = 34;
    document.addEventListener(
      "mousedown",
      (ev) => {
        if (ev.button !== 0 || ev.clientY > DRAG_H) return;
        const el = ev.target as Element | null;
        if (
          el &&
          el.closest("a,button,input,select,textarea,label,[role='button'],[contenteditable],[data-no-drag]")
        ) {
          return; // let Sure's own controls in the titlebar band work
        }
        try {
          tauri?.window?.getCurrentWindow?.().startDragging?.();
        } catch {
          /* IPC unavailable on this page */
        }
      },
      true
    );
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
        // Emit an event (remote pages can emit but not invoke custom commands);
        // Rust listens for "sure://start-sso" and opens the browser.
        // eslint-disable-next-line no-console
        console.log("[sure] SSO intercept -> emit sure://start-sso", m[1]);
        Promise.resolve(emit("sure://start-sso", { server: location.origin, provider: m[1] }))
          // eslint-disable-next-line no-console
          .then(() => console.log("[sure] start-sso emitted"))
          // eslint-disable-next-line no-console
          .catch((e: unknown) => console.error("[sure] start-sso emit failed", e));
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

  // Coalesce bursts of DOM mutations into one scan per frame rather than
  // re-querying the whole document on every mutation.
  let scheduled = false;
  const obs = new MutationObserver(() => {
    if (scheduled) return;
    scheduled = true;
    requestAnimationFrame(() => {
      scheduled = false;
      scan();
    });
  });
  obs.observe(document.documentElement, { childList: true, subtree: true });
  scan();
})();
