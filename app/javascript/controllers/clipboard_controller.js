import { Controller } from "@hotwired/stimulus";

export default class extends Controller {
  static targets = ["source", "iconDefault", "iconSuccess", "textDefault", "textSuccess"];

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
    this.toggleTarget("iconDefault", true);
    this.toggleTarget("iconSuccess", false);
    this.toggleTarget("textDefault", true);
    this.toggleTarget("textSuccess", false);

    clearTimeout(this.resetTimeout);
    this.resetTimeout = setTimeout(() => {
      this.toggleTarget("iconDefault", false);
      this.toggleTarget("iconSuccess", true);
      this.toggleTarget("textDefault", false);
      this.toggleTarget("textSuccess", true);
    }, 2000);
  }

  disconnect() {
    clearTimeout(this.resetTimeout);
  }

  toggleTarget(targetName, hide) {
    const hasTarget = this[`has${targetName[0].toUpperCase()}${targetName.slice(1)}Target`];
    if (!hasTarget) return;

    this[`${targetName}Target`].classList.toggle("hidden", hide);
  }
}
