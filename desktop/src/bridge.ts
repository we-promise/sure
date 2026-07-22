// Injected into the remote Sure page. Emits native-notification + badge events.
(() => {
  const tauri = (window as any).__TAURI__;
  if (!tauri?.event) return;
  const emit = tauri.event.emit as (e: string, p: unknown) => void;

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
