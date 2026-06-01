import { Controller } from "@hotwired/stimulus";

// Connects to data-controller="sync-toast"
//
// Shown when a background sync completes and the family's data has changed.
// - Idle              → morph-refreshes the page after a short delay.
// - Mid-form          → stays put; the user refreshes when ready.
// - A modal <dialog> is open → the toast is deferred (it would otherwise sit
//   dimmed-but-clickable behind the dialog's top-layer backdrop, and a refresh
//   would close the dialog and discard its in-progress input). It is revealed
//   once the dialog closes — the first moment a refresh is actually safe.
export default class extends Controller {
  static values = {
    autoRefreshDelay: { type: Number, default: 2000 },
  };

  connect() {
    if (this.#dialogOpen()) {
      this.#deferUntilDialogCloses();
      return;
    }
    this.#arm();
  }

  disconnect() {
    clearTimeout(this._timer);
    this.#removeDeferredDialogListener();
  }

  // Turbo 8 morph refresh (the app sets `turbo_refreshes_with method: :morph,
  // scroll: :preserve`) instead of window.location.reload(): no white flash,
  // scroll position and `data-turbo-permanent` elements (the AI chat panel)
  // are preserved.
  refresh() {
    clearTimeout(this._timer);
    Turbo.visit(window.location.href, { action: "replace" });
  }

  #arm() {
    if (this.#userIsInteracting()) return; // mid-form: wait for a manual refresh
    this._timer = setTimeout(() => this.refresh(), this.autoRefreshDelayValue);
  }

  #deferUntilDialogCloses() {
    this.element.style.display = "none";
    const dialog = document.querySelector("dialog[open]");
    if (!dialog) {
      this.#reveal();
      return;
    }
    // Keep refs so disconnect() can detach this listener. Otherwise a toast
    // replaced by a newer broadcast while the dialog is still open stays
    // subscribed, and its now-detached controller fires #reveal()/#arm() on
    // close — a spurious auto-refresh from a stale toast.
    this._deferredDialog = dialog;
    this._dialogCloseHandler = () => this.#onDialogClose();
    dialog.addEventListener("close", this._dialogCloseHandler, { once: true });
  }

  #onDialogClose() {
    // The `once` listener has already fired and detached itself.
    this._deferredDialog = null;
    this._dialogCloseHandler = null;
    // Another dialog may still be open (stacked modals) — keep deferring until
    // every dialog has closed.
    if (this.#dialogOpen()) {
      this.#deferUntilDialogCloses();
      return;
    }
    this.#reveal();
  }

  #removeDeferredDialogListener() {
    if (this._deferredDialog && this._dialogCloseHandler) {
      this._deferredDialog.removeEventListener(
        "close",
        this._dialogCloseHandler,
      );
    }
    this._deferredDialog = null;
    this._dialogCloseHandler = null;
  }

  #reveal() {
    this.element.style.display = "";
    this.#arm();
  }

  #dialogOpen() {
    return !!document.querySelector("dialog[open]");
  }

  #userIsInteracting() {
    const el = document.activeElement;
    if (!el || el === document.body || el === document.documentElement)
      return false;
    return (
      el.isContentEditable ||
      el.closest("form, dialog, [role='dialog']") !== null
    );
  }
}
