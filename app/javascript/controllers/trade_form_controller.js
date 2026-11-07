import { Controller } from "@hotwired/stimulus";

// Connects to data-controller="trade-form"
export default class extends Controller {
  static targets = ["holdings"];

  // Reloads the page with a new type without closing the modal
  async changeType(event) {
    const url = new URL(event.params.url, window.location.origin);
    url.searchParams.set(event.params.key, event.target.value);
    Turbo.visit(url, { frame: "modal" });
  }

  // Reloads only the sale picker for the chosen date, so the other fields
  // keep what was typed
  reloadHoldings(event) {
    if (!event.target.value || !this.hasHoldingsTarget) return;

    const url = new URL(event.params.url, window.location.origin);
    url.searchParams.set("date", event.target.value);
    this.holdingsTarget.src = url.toString();
  }
}
