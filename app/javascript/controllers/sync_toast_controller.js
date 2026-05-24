import { Controller } from "@hotwired/stimulus";

// Connects to data-controller="sync-toast"
//
// Shown when a background sync completes and the family's data changes.
// - If the user is not interacting with a form, auto-reloads after a short delay.
// - If the user is mid-form, the toast stays visible so they can choose when to refresh.
export default class extends Controller {
  static values = {
    autoRefreshDelay: { type: Number, default: 500 },
  };

  connect() {
    if (!this.#userIsInteracting()) {
      this._timer = setTimeout(() => this.refresh(), this.autoRefreshDelayValue);
    }
  }

  disconnect() {
    clearTimeout(this._timer);
  }

  refresh() {
    clearTimeout(this._timer);
    window.location.reload();
  }

  #userIsInteracting() {
    const el = document.activeElement;
    if (!el || el === document.body || el === document.documentElement) return false;
    return el.closest("form") !== null;
  }
}
