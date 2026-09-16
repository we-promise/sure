import { Controller } from "@hotwired/stimulus";

// Preserves the settings content scroll position PER PAGE across Turbo Drive
// navigation. Settings nav items are plain links (full-body Turbo visits), and
// Turbo only restores window scroll — so this nested overflow-y-auto container
// snaps to top on every visit.
//
// Keyed by pathname: returning to a page restores its scroll, a brand-new page
// starts at the top, and a same-page re-render (e.g. a settings form that
// auto-submits) keeps scroll. This differs from the nav's `preserve-scroll`
// controller, which intentionally carries one position across all pages because
// the nav is the same persistent element on every settings page.
export default class extends Controller {
  static positions = {};

  connect() {
    this.save = this.save.bind(this);
    document.addEventListener("turbo:before-cache", this.save);
    this.restore();
  }

  disconnect() {
    document.removeEventListener("turbo:before-cache", this.save);
  }

  save() {
    this.constructor.positions[window.location.pathname] = {
      top: this.element.scrollTop,
      left: this.element.scrollLeft,
    };
  }

  restore() {
    const pos = this.constructor.positions[window.location.pathname];
    if (!pos) return;
    this.element.scrollTop = pos.top;
    this.element.scrollLeft = pos.left;
  }
}
