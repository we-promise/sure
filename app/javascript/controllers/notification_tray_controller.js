import { Controller } from "@hotwired/stimulus";

// The tray is `position: fixed` with `left: 50%` (viewport-center) by
// default, which is correct for every single-column layout. Layouts with a
// sidebar (app, settings) opt in here so the tray centers on the actual
// content pane instead. A ResizeObserver on <main> catches every case that
// moves its bounds — window resize, sidebar drag-resize, sidebar
// collapse/expand — since all of those already reflow <main> natively; no
// cooperation needed from the sidebar controllers themselves.
export default class extends Controller {
  static targets = ["tray", "main"];

  connect() {
    this.resizeObserver = new ResizeObserver(() => this.reposition());
    this.resizeObserver.observe(this.mainTarget);
    this.reposition();

    this._deferredStreams = [];
    this._onBeforeStreamRender = this.#deferWhileDialogOpen.bind(this);
    this._onDialogClose = this.#onDialogClose.bind(this);
    document.addEventListener(
      "turbo:before-stream-render",
      this._onBeforeStreamRender,
    );
    // `close` doesn't bubble; a capturing listener still sees every dialog's.
    document.addEventListener("close", this._onDialogClose, true);
  }

  disconnect() {
    this.resizeObserver?.disconnect();
    document.removeEventListener(
      "turbo:before-stream-render",
      this._onBeforeStreamRender,
    );
    document.removeEventListener("close", this._onDialogClose, true);
    this._dialogRemovalObserver?.disconnect();
  }

  reposition() {
    const rect = this.mainTarget.getBoundingClientRect();
    this.trayTarget.style.left = `${rect.left + rect.width / 2}px`;
  }

  // turbo_refreshes_with(method: :morph) is enabled app-wide
  // (_head.html.erb), and idiomorph resets any inline style a client
  // script set that isn't present in the freshly-fetched server HTML —
  // which `left` always is. `data-turbo-permanent` looked like the fix,
  // but it invokes idiomorph's node-identity matching (same id preserved
  // across ANY morphed page), which misbehaves once the id also exists
  // on structurally different layouts (app vs settings). Wiring this
  // narrower per-attribute event as a declarative action instead blocks
  // only `style` on this one element — no node-identity system involved.
  preserveStyle(event) {
    if (event.detail.attributeName === "style") event.preventDefault();
  }

  // A native <dialog> shown via showModal() (the transaction drawer, any
  // modal) renders in the browser's top layer, which sits above this tray
  // regardless of z-index. A "create a rule?" CTA streaming in while one is
  // open is invisible and unclickable until the dialog closes, and by then
  // its one-time flash has already been consumed server-side, so it never
  // gets a second chance to render. Hold the stream's render until no dialog
  // is open any more.
  //
  // Separately, some background jobs (e.g. Account::SyncCompleteEvent)
  // broadcast a raw <turbo-stream action="refresh"> with no target: a
  // full-page morph that bypasses the sync-toast controller's own
  // dialog/CTA-aware deferral entirely, since Turbo handles "refresh"
  // itself rather than routing it through that Stimulus controller. Left
  // alone, one of these can silently wipe an unread CTA a moment after it
  // was revealed. Hold those the same way, and skip them while a CTA is
  // waiting for the user.
  #deferWhileDialogOpen(event) {
    const stream = event.target;
    const isCta = stream.target === "cta";
    const isRefresh = stream.action === "refresh";
    if (!isCta && !isRefresh) return;

    if (!this.#dialogOpen()) {
      if (isRefresh && this.#ctaPending()) event.detail.render = () => {};
      return;
    }

    const render = event.detail.render;
    event.detail.render = (streamElement) => {
      this._deferredStreams.push({ isRefresh, render, streamElement });
      // Turbo calls this after waiting for the next paint; the dialog may
      // have closed in between, with no close event left to release it.
      this.#flushIfNoDialogOpen();
      if (this._deferredStreams.length > 0) this.#watchForDialogRemoval();
    };
  }

  // Captured on the document rather than bound to the dialog that was open
  // when the stream arrived, so stacked dialogs and a drawer replaced by the
  // next one are both covered. A dialog can also leave the DOM without any
  // close event (a frame replaced by a stream, one drawer swapped for the
  // next), which the mutation observer catches while streams are waiting.
  #onDialogClose(event) {
    if (event.target instanceof HTMLDialogElement) this.#flushIfNoDialogOpen();
  }

  #watchForDialogRemoval() {
    this._dialogRemovalObserver ??= new MutationObserver(() =>
      this.#flushIfNoDialogOpen(),
    );
    // `open` too: a dialog closed by dropping the attribute fires no close event.
    this._dialogRemovalObserver.observe(document.body, {
      childList: true,
      subtree: true,
      attributes: true,
      attributeFilter: ["open"],
    });
  }

  #flushIfNoDialogOpen() {
    if (this._deferredStreams.length === 0 || this.#dialogOpen()) return;

    this._dialogRemovalObserver?.disconnect();
    const streams = this._deferredStreams;
    this._deferredStreams = [];

    // CTAs first: a refresh morphs the page to the server's HTML, where the
    // already-consumed CTA no longer exists.
    for (const { isRefresh, render, streamElement } of streams) {
      if (!isRefresh) render(streamElement);
    }
    const refresh = streams.find(({ isRefresh }) => isRefresh);
    if (refresh && !this.#ctaPending()) refresh.render(refresh.streamElement);
  }

  #dialogOpen() {
    return !!document.querySelector("dialog[open]");
  }

  #ctaPending() {
    return !!document.getElementById("cta")?.firstElementChild;
  }
}
