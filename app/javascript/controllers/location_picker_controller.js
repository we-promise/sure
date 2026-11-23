import { Controller } from "@hotwired/stimulus";
import L from "leaflet";

// Connects to data-controller="location-picker"
export default class extends Controller {
  static targets = [
    "lat",
    "lng",
    "name",
    "display",
    "displayText",
    "search",
    "searchInput",
    "suggestions",
    "confirmMap",
  ];

  static values = {
    searchUnavailable: String,
    noMatches: String,
    tileUrl: String,
    tileAttribution: String,
  };

  connect() {
    this.marker = null;
    this.confirmMapInstance = null;
    this.dragGeneration = 0;
  }

  disconnect() {
    clearTimeout(this.debounceTimeout);
    this.confirmMapInstance?.remove();
  }

  search(event) {
    const query = event.target.value.trim();

    clearTimeout(this.debounceTimeout);
    if (query.length < 3) {
      this.suggestionsTarget.replaceChildren();
      return;
    }

    this.debounceTimeout = setTimeout(() => this.#fetchSuggestions(query), 300);
  }

  select(event) {
    const { lat, lng, name } = event.params;
    this.#showConfirmMap(lat, lng, name);
  }

  clear() {
    this.latTarget.value = "";
    this.lngTarget.value = "";
    this.nameTarget.value = "";
    this.displayTarget.classList.add("hidden");
    this.searchTarget.classList.remove("hidden");
    this.confirmMapTarget.classList.add("hidden");
    this.confirmMapInstance?.remove();
    this.confirmMapInstance = null;
    this.#submitForm();
  }

  async #fetchSuggestions(query) {
    const response = await fetch(
      `/location_searches?q=${encodeURIComponent(query)}`,
      {
        headers: { Accept: "application/json" },
      },
    );

    if (!response.ok) {
      this.#renderMessage(this.searchUnavailableValue);
      return;
    }

    const results = await response.json();

    if (results.length === 0) {
      this.#renderMessage(this.noMatchesValue);
      return;
    }

    this.suggestionsTarget.replaceChildren();
    results.forEach((result) => {
      const item = document.createElement("li");
      item.textContent = result.display_name;
      // Focusable so a keyboard-only user can reach a suggestion, and Enter or
      // Space picks it — clicking is not the only way in.
      item.setAttribute("role", "option");
      item.setAttribute("aria-selected", "false");
      item.tabIndex = 0;
      item.dataset.action =
        "click->location-picker#select keydown.enter->location-picker#select:prevent keydown.space->location-picker#select:prevent";
      item.dataset.locationPickerLatParam = result.lat;
      item.dataset.locationPickerLngParam = result.lng;
      item.dataset.locationPickerNameParam = result.display_name;
      this.suggestionsTarget.appendChild(item);
    });
  }

  // A status line, not a choice, so it stays out of the listbox's options.
  #renderMessage(text) {
    const item = document.createElement("li");
    item.setAttribute("role", "presentation");
    item.textContent = text;
    this.suggestionsTarget.replaceChildren(item);
  }

  #showConfirmMap(lat, lng, name) {
    this.latTarget.value = lat;
    this.lngTarget.value = lng;
    this.nameTarget.value = name;
    this.displayTextTarget.textContent = name;

    this.searchTarget.classList.add("hidden");
    this.displayTarget.classList.remove("hidden");
    this.confirmMapTarget.classList.remove("hidden");

    this.confirmMapInstance?.remove();
    this.confirmMapInstance = L.map(this.confirmMapTarget).setView(
      [lat, lng],
      15,
    );
    L.tileLayer(this.tileUrlValue, {
      attribution: this.tileAttributionValue,
    }).addTo(this.confirmMapInstance);

    this.marker = L.marker([lat, lng], { draggable: true }).addTo(
      this.confirmMapInstance,
    );
    this.marker.on("dragend", () => this.#onDrag());

    this.#submitForm();
  }

  async #onDrag() {
    const generation = ++this.dragGeneration;
    const { lat, lng } = this.marker.getLatLng();
    this.latTarget.value = lat;
    this.lngTarget.value = lng;

    const response = await fetch(
      `/location_searches/reverse?lat=${lat}&lng=${lng}`,
      {
        headers: { Accept: "application/json" },
      },
    );

    if (generation !== this.dragGeneration) return;

    if (response.ok) {
      const result = await response.json();
      if (generation !== this.dragGeneration) return;
      this.nameTarget.value = result.display_name;
      this.displayTextTarget.textContent = result.display_name;
    }

    this.#submitForm();
  }

  #submitForm() {
    const form = this.element.closest("form");
    const controllers = (form?.dataset.controller || "").split(/\s+/);
    if (form && controllers.includes("auto-submit-form")) {
      form.requestSubmit();
    }
  }
}
