import { Controller } from "@hotwired/stimulus";

// Connects to data-controller="permanent-frame"
//
// For a data-turbo-permanent frame whose id carries a data version (the
// sidebar sparklines). Turbo Drive visits keep the loaded frame when the new
// page has the same id. A morph refresh never removes permanent elements, so
// when the new page no longer has this id (the data changed), drop the
// permanent flag and let the morph replace the frame with the fresh one.
export default class extends Controller {
  connect() {
    document.addEventListener("turbo:before-render", this.releaseIfStale);
  }

  disconnect() {
    document.removeEventListener("turbo:before-render", this.releaseIfStale);
  }

  releaseIfStale = (event) => {
    if (event.detail.renderMethod !== "morph") return;

    const selector = `#${CSS.escape(this.element.id)}`;
    if (!event.detail.newBody.querySelector(selector)) {
      this.element.removeAttribute("data-turbo-permanent");
    }
  };
}
