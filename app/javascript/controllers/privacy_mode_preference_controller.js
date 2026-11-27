import { Controller } from "@hotwired/stimulus";

// Connects to data-controller="privacy-mode-preference"
//
// Mirrors the "Blur charts" toggle onto <html> the moment it changes. The
// settings layout does not host the privacy-mode controller, so the choice
// would otherwise show only once a page with the application layout
// renders. Turbo's snapshot cache is dropped too: a Back visit to the
// dashboard would otherwise restore a snapshot rendered under the old
// choice and re-apply it.
export default class extends Controller {
  apply(event) {
    document.documentElement.classList.toggle(
      "privacy-numbers-only",
      !event.target.checked,
    );
    window.Turbo?.cache.clear();
  }
}
