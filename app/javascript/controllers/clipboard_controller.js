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
    this._setSuccessState(true);

    this._clearResetTimeout();
    this.resetTimeout = setTimeout(() => {
      this._setSuccessState(false);
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

  _setSuccessState(successVisible) {
    this._toggleIfTargetExists(this.hasIconDefaultTarget, this.iconDefaultTarget, successVisible);
    this._toggleIfTargetExists(this.hasIconSuccessTarget, this.iconSuccessTarget, !successVisible);
    this._toggleIfTargetExists(this.hasTextDefaultTarget, this.textDefaultTarget, successVisible);
    this._toggleIfTargetExists(this.hasTextSuccessTarget, this.textSuccessTarget, !successVisible);
  }

  _toggleIfTargetExists(hasTarget, target, hide) {
    if (!hasTarget) return;
    target.classList.toggle("hidden", hide);
  }
}
