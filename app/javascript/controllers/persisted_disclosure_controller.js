import { Controller } from "@hotwired/stimulus";

// Remembers whether a <details> section is open, per device, so a panel the
// user has collapsed stays collapsed instead of reappearing on every render.
// Same storage approach as privacy mode and the sidebar width.
//
// The element keeps its server-rendered `open` state until connect() runs, so
// a collapsed section flashes open for a frame on a cold load. Reading storage
// in connect() rather than waiting for a turbo event keeps that to one frame.
export default class extends Controller {
  static values = { key: String };

  connect() {
    const stored = localStorage.getItem(this.storageKey);
    if (stored !== null) this.element.open = stored === "true";

    this.toggleHandler = () => {
      localStorage.setItem(this.storageKey, String(this.element.open));
    };
    this.element.addEventListener("toggle", this.toggleHandler);
  }

  disconnect() {
    this.element.removeEventListener("toggle", this.toggleHandler);
  }

  get storageKey() {
    return `disclosure:${this.keyValue}`;
  }
}
