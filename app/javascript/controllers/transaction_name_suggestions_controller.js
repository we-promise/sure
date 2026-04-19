import { Controller } from "@hotwired/stimulus";

export default class extends Controller {
  static targets = ["input", "list", "menu", "empty"];
  static values = {
    url: String,
    minLength: { type: Number, default: 2 },
    debounce: { type: Number, default: 150 },
  };

  connect() {
    this.abortController = null;
    this.activeIndex = -1;
    this.suggestions = [];
    this.boundSelectSuggestion = this.selectSuggestion.bind(this);
  }

  disconnect() {
    this.#cancelPendingRequest();
    clearTimeout(this.timeout);
  }

  fetchSuggestions() {
    clearTimeout(this.timeout);

    const query = this.inputTarget.value.trim();
    if (query.length < this.minLengthValue) {
      this.#resetSuggestions();
      return;
    }

    this.timeout = setTimeout(() => {
      this.#loadSuggestions(query);
    }, this.debounceValue);
  }

  handleFocus() {
    if (this.inputTarget.value.trim().length >= this.minLengthValue && this.suggestions.length === 0) {
      this.fetchSuggestions();
      return;
    }

    if (this.inputTarget.value.trim().length >= this.minLengthValue && this.suggestions.length > 0) {
      this.#showMenu();
    }
  }

  handleBlur() {
    window.setTimeout(() => this.#hideMenu(), 120);
  }

  handleKeydown(event) {
    if (!this.#menuOpen() || this.suggestions.length === 0) {
      return;
    }

    switch (event.key) {
      case "ArrowDown":
        event.preventDefault();
        this.#moveActiveIndex(1);
        break;
      case "ArrowUp":
        event.preventDefault();
        this.#moveActiveIndex(-1);
        break;
      case "Enter":
        if (this.activeIndex >= 0) {
          event.preventDefault();
          this.#selectSuggestion(this.suggestions[this.activeIndex]);
        }
        break;
      case "Escape":
        this.#hideMenu();
        break;
    }
  }

  selectSuggestion(event) {
    event.preventDefault();
    event.stopPropagation();

    const { value } = event.currentTarget.dataset;
    this.#selectSuggestion(value);
  }

  async #loadSuggestions(query) {
    if (!this.hasUrlValue) return;

    const url = new URL(this.urlValue, window.location.origin);
    url.searchParams.set("query", query);

    this.#cancelPendingRequest();
    this.abortController = new AbortController();

    try {
      const response = await fetch(url.toString(), {
        headers: { Accept: "application/json" },
        signal: this.abortController.signal,
      });

      if (!response.ok) return;

      const data = await response.json();
      this.suggestions = data.suggestions || [];
      this.activeIndex = -1;
      this.#renderSuggestions();
    } catch (error) {
      if (error.name !== "AbortError") {
        this.#resetSuggestions();
      }
    }
  }

  #renderSuggestions() {
    this.listTarget.innerHTML = "";

    if (this.suggestions.length === 0) {
      this.emptyTarget.classList.remove("hidden");
      this.#showMenu();
      this.#updateExpandedState(true);
      return;
    }

    this.emptyTarget.classList.add("hidden");

    this.suggestions.forEach((suggestion, index) => {
      const item = document.createElement("li");
      item.id = `transaction-name-suggestion-${index}`;
      item.setAttribute("role", "option");
      item.setAttribute("aria-selected", "false");
      item.dataset.index = index;
      item.dataset.value = suggestion;
      item.className =
        "cursor-pointer rounded-lg px-3 py-2 text-sm text-primary hover:bg-container-inset-hover";
      item.textContent = suggestion;
      item.addEventListener("mousedown", this.boundSelectSuggestion);

      this.listTarget.appendChild(item);
    });

    this.#showMenu();
    this.#updateExpandedState(true);
  }

  #moveActiveIndex(direction) {
    const nextIndex = this.activeIndex + direction;

    if (nextIndex < 0) {
      this.activeIndex = this.suggestions.length - 1;
    } else if (nextIndex >= this.suggestions.length) {
      this.activeIndex = 0;
    } else {
      this.activeIndex = nextIndex;
    }

    this.#syncActiveOption();
  }

  #syncActiveOption() {
    Array.from(this.listTarget.children).forEach((item, index) => {
      const isActive = index === this.activeIndex;
      item.setAttribute("aria-selected", isActive ? "true" : "false");
      item.classList.toggle("bg-container-inset", isActive);

      if (isActive) {
        item.scrollIntoView({ block: "nearest" });
        this.inputTarget.setAttribute("aria-activedescendant", item.id);
      }
    });

    if (this.activeIndex < 0) {
      this.inputTarget.removeAttribute("aria-activedescendant");
    }
  }

  #selectSuggestion(value) {
    this.inputTarget.value = value;
    this.#resetSuggestions();
  }

  #showMenu() {
    this.menuTarget.classList.remove("hidden");
  }

  #hideMenu() {
    this.menuTarget.classList.add("hidden");
    this.#updateExpandedState(false);
    this.inputTarget.removeAttribute("aria-activedescendant");
  }

  #menuOpen() {
    return !this.menuTarget.classList.contains("hidden");
  }

  #updateExpandedState(expanded) {
    this.inputTarget.setAttribute("aria-expanded", expanded ? "true" : "false");
  }

  #resetSuggestions() {
    this.suggestions = [];
    this.activeIndex = -1;
    this.listTarget.innerHTML = "";
    this.emptyTarget.classList.add("hidden");
    this.#hideMenu();
  }

  #cancelPendingRequest() {
    if (!this.abortController) return;
    this.abortController.abort();
    this.abortController = null;
  }
}
