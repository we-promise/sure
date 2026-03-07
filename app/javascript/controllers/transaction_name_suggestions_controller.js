import { Controller } from "@hotwired/stimulus";

export default class extends Controller {
  static targets = ["input", "datalist"];
  static values = {
    url: String,
    debounce: { type: Number, default: 200 },
  };

  connect() {
    this.abortController = null;
    this.timeout = null;
  }

  disconnect() {
    this.#cancelPendingRequest();
    clearTimeout(this.timeout);
  }

  fetchSuggestions() {
    clearTimeout(this.timeout);

    this.timeout = setTimeout(() => {
      this.#loadSuggestions(this.inputTarget.value.trim());
    }, this.debounceValue);
  }

  async #loadSuggestions(query) {
    if (!this.hasUrlValue) return;

    const url = new URL(this.urlValue, window.location.origin);
    if (query.length > 0) {
      url.searchParams.set("query", query);
    }

    this.#cancelPendingRequest();
    this.abortController = new AbortController();

    try {
      const response = await fetch(url.toString(), {
        headers: { Accept: "application/json" },
        signal: this.abortController.signal,
      });

      if (!response.ok) return;

      const data = await response.json();
      this.#renderOptions(data.suggestions || []);
    } catch (error) {
      if (error.name !== "AbortError") {
        // Keep the existing suggestion list if fetch fails.
      }
    }
  }

  #renderOptions(suggestions) {
    this.datalistTarget.innerHTML = "";

    suggestions.forEach((name) => {
      const option = document.createElement("option");
      option.value = name;
      this.datalistTarget.appendChild(option);
    });
  }

  #cancelPendingRequest() {
    if (!this.abortController) return;
    this.abortController.abort();
    this.abortController = null;
  }
}
