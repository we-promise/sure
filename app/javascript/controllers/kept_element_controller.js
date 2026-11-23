import { Controller } from "@hotwired/stimulus";

// Connects to data-controller="kept-element", on a permanent sidebar element
// (a sparkline frame's wrapper, an account logo's).
//
// On a visit, Turbo carries a permanent element into the new page only when
// that page has one with the same id, and drops it otherwise. A morph refresh
// (what the sync toast triggers) never removes a permanent element, so one
// whose id the refreshed page no longer has — its content changed — would
// stay beside the new one, stacking a copy per refresh. The element removes
// itself before such a morph.
//
// One that has dropped its permanence (a sparkline that timed out, a logo
// that failed) removes itself too, even when the refreshed page has the same
// id: the morph would make it permanent again and keep what it shows, such as
// a frame back on its placeholder that never loads again, where the refreshed
// page's own copy fetches afresh.
export default class extends Controller {
  dropIfGone(event) {
    const { renderMethod, newBody } = event.detail;
    if (renderMethod !== "morph" || !newBody) return;

    const failed = !this.element.hasAttribute("data-turbo-permanent");
    if (failed || !newBody.querySelector(`#${CSS.escape(this.element.id)}`)) {
      this.element.remove();
    }
  }
}
