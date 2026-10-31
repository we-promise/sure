import { Controller } from "@hotwired/stimulus";

// Asks the server for the schedule the current form would create. The server
// runs the loan engine, so the dialog never grows a second copy of the EMI
// formula.
export default class extends Controller {
  static targets = ["estimate"];
  static values = { url: String, error: String };

  disconnect() {
    clearTimeout(this.timeout);
    this.abortController?.abort();
  }

  update() {
    clearTimeout(this.timeout);
    this.timeout = setTimeout(() => this.refresh(), 250);
  }

  async refresh() {
    // Only the plan fields belong in the estimate URL. A full FormData would
    // also put the CSRF token and _method in the query string.
    const params = new URLSearchParams();
    for (const [key, value] of new FormData(this.element)) {
      if (key.startsWith("installment_plan[")) params.append(key, value);
    }

    this.abortController?.abort();
    this.abortController = new AbortController();

    try {
      const response = await fetch(`${this.urlValue}?${params}`, {
        headers: { Accept: "text/html" },
        signal: this.abortController.signal,
      });
      if (response.redirected || !response.ok) {
        this.showUnavailable();
        return;
      }

      this.estimateTarget.innerHTML = await response.text();
    } catch (error) {
      if (error.name !== "AbortError") {
        console.error(error);
        this.showUnavailable();
      }
    }
  }

  showUnavailable() {
    const paragraph = document.createElement("p");
    paragraph.className = "text-xs text-secondary";
    paragraph.textContent = this.errorValue;
    this.estimateTarget.replaceChildren(paragraph);
  }
}
