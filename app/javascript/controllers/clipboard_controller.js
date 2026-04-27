import { Controller } from "@hotwired/stimulus";

export default class extends Controller {
  static targets = ["source", "iconDefault", "iconSuccess"];

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
    if (!this.hasIconDefaultTarget || !this.hasIconSuccessTarget) return;

    this.iconDefaultTarget.classList.add("hidden");
    this.iconSuccessTarget.classList.remove("hidden");

    clearTimeout(this.resetTimeout);
    this.resetTimeout = setTimeout(() => {
      this.iconDefaultTarget.classList.remove("hidden");
      this.iconSuccessTarget.classList.add("hidden");
      this.resetTimeout = null;
    }, 3000);
  }

  disconnect() {
    clearTimeout(this.resetTimeout);
    this.resetTimeout = null;
  }
}
