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

    // turbo_refreshes_with(method: :morph) is enabled app-wide
    // (_head.html.erb), and idiomorph resets any inline style a client
    // script set that isn't present in the freshly-fetched server HTML —
    // which `left` always is. `data-turbo-permanent` looked like the fix,
    // but it invokes idiomorph's node-identity matching (same id preserved
    // across ANY morphed page), which misbehaves once the id also exists
    // on structurally different layouts (app vs settings). This listens for
    // the narrower per-attribute event instead and blocks only `style` on
    // this one element — no node-identity system involved.
    this.trayTarget.addEventListener("turbo:before-morph-attribute", this.preserveStyle);
  }

  disconnect() {
    this.resizeObserver?.disconnect();
    this.trayTarget.removeEventListener("turbo:before-morph-attribute", this.preserveStyle);
  }

  reposition() {
    const rect = this.mainTarget.getBoundingClientRect();
    this.trayTarget.style.left = `${rect.left + rect.width / 2}px`;
  }

  preserveStyle = (event) => {
    if (event.detail.attributeName === "style") event.preventDefault();
  };
}
