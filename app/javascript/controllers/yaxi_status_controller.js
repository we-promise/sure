import { Controller } from "@hotwired/stimulus";

export default class extends Controller {
  static targets = ["progress", "progressText", "error", "errorText"];

  busy(event) {
    this.errorTarget.classList.add("hidden");
    this.progressTextTarget.textContent = event.detail.value;
    this.progressTarget.classList.remove("hidden");
  }

  clear() {
    this.progressTarget.classList.add("hidden");
  }

  error(event) {
    this.clear();
    const error = event.detail.value;
    this.errorTextTarget.textContent = typeof error === "string"
      ? error
      : error.userMessage || error.toString();
    this.errorTarget.classList.remove("hidden");
  }
}
