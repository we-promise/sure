import { Controller } from "@hotwired/stimulus";

export default class extends Controller {
  static targets = ["source", "iconDefault", "iconSuccess", "textDefault", "textSuccess"];
  static values = { successDuration: { type: Number, default: 2500 } };

  copy(event) {
    event.preventDefault();
    if (this.sourceTarget?.textContent) {
      navigator.clipboard
        .writeText(this.sourceTarget.textContent)
        .then(() => {
          this.showSuccess();
        })
        .catch((error) => {
          console.error("Failed to copy text: ", error);
        });
    }
  }

  showSuccess() {
    this._toggleTarget("iconDefault", true);
    this._toggleTarget("iconSuccess", false);
    this._toggleTarget("textDefault", true);
    this._toggleTarget("textSuccess", false);

    this._clearResetTimeout();
    this.resetTimeout = setTimeout(() => {
      this._toggleTarget("iconDefault", false);
      this._toggleTarget("iconSuccess", true);
      this._toggleTarget("textDefault", false);
      this._toggleTarget("textSuccess", true);
      this.resetTimeout = null;
    }, this.successDurationValue);
  }

  disconnect() {
    this._clearResetTimeout();
  }

  _clearResetTimeout() {
    clearTimeout(this.resetTimeout);
    this.resetTimeout = null;
  }

  _toggleTarget(targetName, hide) {
    const hasTarget = this[`has${targetName[0].toUpperCase()}${targetName.slice(1)}Target`];
    if (!hasTarget) return;

    this[`${targetName}Target`].classList.toggle("hidden", hide);
  }
}
