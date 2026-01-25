import { Controller } from "@hotwired/stimulus";

// Connects to data-controller="auto-open"
// Auto-opens a <details> element based on URL param
// Use data-auto-open-param-value="paramName" to open when ?paramName=1 is in URL
export default class extends Controller {
  static values = { param: String };

  connect() {
    if (!this.hasParamValue || !this.paramValue) return;

    const params = new URLSearchParams(window.location.search);
    if (params.get(this.paramValue) === "1") {
      this.element.open = true;

      // Clean up the URL param after opening
      params.delete(this.paramValue);
      const newUrl = params.toString()
        ? `${window.location.pathname}?${params.toString()}${window.location.hash}`
        : `${window.location.pathname}${window.location.hash}`;
      window.history.replaceState({}, "", newUrl);

      // Scroll into view after opening
      requestAnimationFrame(() => {
        this.element.scrollIntoView({ behavior: "smooth", block: "start" });
      });
    }
  }
}
