import { Controller } from "@hotwired/stimulus";

export default class extends Controller {
  get headers() {
    return {
      Accept: "application/json",
      "Content-Type": "application/json",
      "X-CSRF-Token": document.querySelector("meta[name='csrf-token']")
        ?.content,
    };
  }

  async errorMessage(response) {
    try {
      const result = await response.clone().json();
      if (result.error) return result.error;
    } catch (_error) {
      return this.errorFallbackValue;
    }

    return this.errorFallbackValue;
  }

  showError(message) {
    if (this.hasErrorTarget) {
      this.errorTarget.textContent = message;
      this.errorTarget.hidden = false;
      this.errorTarget.setAttribute("aria-hidden", "false");
    }
  }

  clearError() {
    if (this.hasErrorTarget) {
      this.errorTarget.textContent = "";
      this.errorTarget.hidden = true;
      this.errorTarget.setAttribute("aria-hidden", "true");
    }
  }
}
