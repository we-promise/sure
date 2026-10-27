import { Controller } from "@hotwired/stimulus";

// Connects to data-controller="lazy-load"
// Used with <details> elements to lazy-load content when expanded
// Use data-action="toggle->lazy-load#toggled" on the <details> element
export default class extends Controller {
  static targets = ["content", "loading", "frame"];
  static values = { url: String, loaded: Boolean, failureMessage: String, networkErrorMessage: String };

  connect() {
    // If already open on connect (rendered open, or browser restored state), load immediately
    if (this.element.open && !this.loadedValue) {
      this.load();
    }
  }

  toggled() {
    if (this.element.open && !this.loadedValue) {
      this.load();
    }
  }

  async load() {
    if (this.loadedValue || this.loading) return;
    this.loading = true;

    try {
      const csrfToken = document.querySelector('meta[name="csrf-token"]')?.content;
      const response = await fetch(this.urlValue, {
        headers: {
          Accept: "text/html",
          "X-Requested-With": "XMLHttpRequest",
          "X-CSRF-Token": csrfToken,
        },
        credentials: "same-origin",
      });

      if (response.ok) {
        const html = await response.text();
        if (this.hasFrameTarget) {
          this.frameTarget.innerHTML = html;
        }
        if (this.hasLoadingTarget) {
          this.loadingTarget.classList.add("hidden");
        }
        this.loadedValue = true;
      } else {
        console.error("Lazy load failed:", response.status, response.statusText);
        this.showError(this.failureMessageValue.replace("%{status}", String(response.status)));
      }
    } catch (error) {
      console.error("Lazy load error:", error);
      this.showError(this.networkErrorMessageValue);
    } finally {
      this.loading = false;
    }
  }

  showError(message) {
    if (this.hasLoadingTarget) {
      const error = document.createElement("p");
      error.className = "text-destructive text-sm";
      error.textContent = message;
      this.loadingTarget.replaceChildren(error);
    }
  }
}
