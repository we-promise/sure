import { Controller } from "@hotwired/stimulus";

// Remembers which account sidebar groups the user expanded or collapsed, per
// browser, so a refresh or navigation does not reset them. The server only
// knows which group holds the current account, so the saved choice wins.
const STORAGE_KEY = "accountSidebarGroupState";

function readState() {
  try {
    const raw = localStorage.getItem(STORAGE_KEY);
    const parsed = raw ? JSON.parse(raw) : {};
    return parsed && typeof parsed === "object" ? parsed : {};
  } catch (_) {
    return {};
  }
}

function writeState(state) {
  try {
    localStorage.setItem(STORAGE_KEY, JSON.stringify(state));
  } catch (_) {}
}

export default class extends Controller {
  static values = { key: String };

  connect() {
    this.restore();
  }

  get details() {
    return this.element.querySelector("details");
  }

  restore() {
    const details = this.details;
    if (!details || !this.keyValue) return;

    const saved = readState()[this.keyValue];
    if (typeof saved !== "boolean" || details.open === saved) return;

    this.restoring = true;
    details.open = saved;
    // `toggle` fires asynchronously; ignore the one this change causes.
    setTimeout(() => {
      this.restoring = false;
    }, 0);
  }

  save(event) {
    const details = this.details;
    if (!details || event.target !== details || this.restoring || !this.keyValue) return;
    // Sort mode opens collapsed groups only while sorting; don't remember that.
    if (document.querySelector("[data-account-sort-mode-target='bar']:not([style*='display: none']):not([style*='display:none'])")) return;

    const state = readState();
    state[this.keyValue] = details.open;
    writeState(state);
  }
}
