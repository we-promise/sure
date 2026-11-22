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

  connect() {
    this.marker = null;
    this.confirmMapInstance = null;
  }

  disconnect() {
    this.confirmMapInstance?.remove();
  }

  search(event) {
    const query = event.target.value.trim();

    clearTimeout(this.debounceTimeout);
    if (query.length < 3) {
      this.suggestionsTarget.innerHTML = "";
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
    this.element.closest("form").requestSubmit();
  }

  async #fetchSuggestions(query) {
    const response = await fetch(
      `/location_searches?q=${encodeURIComponent(query)}`,
      {
        headers: { Accept: "application/json" },
      },
    );

    if (!response.ok) {
      this.suggestionsTarget.innerHTML = `<li>${this.#t("search_unavailable")}</li>`;
      return;
    }

    const results = await response.json();

    if (results.length === 0) {
      this.suggestionsTarget.innerHTML = `<li>${this.#t("no_matches")}</li>`;
      return;
    }

    this.suggestionsTarget.innerHTML = "";
    results.forEach((result) => {
      const item = document.createElement("li");
      item.textContent = result.display_name;
      item.dataset.action = "click->location-picker#select";
      item.dataset.locationPickerLatParam = result.lat;
      item.dataset.locationPickerLngParam = result.lng;
      item.dataset.locationPickerNameParam = result.display_name;
      this.suggestionsTarget.appendChild(item);
    });
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
    L.tileLayer("https://tile.openstreetmap.org/{z}/{x}/{y}.png", {
      attribution: "&copy; OpenStreetMap contributors",
    }).addTo(this.confirmMapInstance);

    this.marker = L.marker([lat, lng], { draggable: true }).addTo(
      this.confirmMapInstance,
    );
    this.marker.on("dragend", () => this.#onDrag());

    this.element.closest("form").requestSubmit();
  }

  async #onDrag() {
    const { lat, lng } = this.marker.getLatLng();
    this.latTarget.value = lat;
    this.lngTarget.value = lng;

    const response = await fetch(
      `/location_searches/reverse?lat=${lat}&lng=${lng}`,
      {
        headers: { Accept: "application/json" },
      },
    );

    if (response.ok) {
      const result = await response.json();
      this.nameTarget.value = result.display_name;
      this.displayTextTarget.textContent = result.display_name;
    }

    this.element.closest("form").requestSubmit();
  }

  #t(key) {
    const messages = {
      search_unavailable: "Search unavailable, try again",
      no_matches: "No matches, try a different search",
    };
    return messages[key];
  }
}
