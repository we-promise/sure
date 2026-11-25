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
    canAnnotate: Boolean,
  };

  connect() {
    this.marker = null;
    this.confirmMapInstance = null;
    this.dragGeneration = 0;
    this.searchGeneration = 0;
    // What the server actually has saved, so a failed or superseded submit
    // can restore the picker instead of leaving an unsaved change on screen.
    this.savedState = {
      lat: this.latTarget.value,
      lng: this.lngTarget.value,
      name: this.nameTarget.value,
    };
  }

  disconnect() {
    this.confirmMapInstance?.remove();
  }

  // Fires once per explicit Enter press, not per keystroke: Nominatim's usage
  // policy prohibits autocomplete/type-ahead style querying, so this is a
  // single discrete search a user asks for, not a live suggestion stream.
  search(event) {
    const generation = ++this.searchGeneration;
    const query = event.target.value.trim();
    if (query.length < 3) {
      this.suggestionsTarget.replaceChildren();
      return;
    }

    this.#fetchSuggestions(query, generation);
  }

  select(event) {
    // A stale reverse-lookup from a drag on the location this is replacing
    // must not land after the new one is confirmed.
    this.dragGeneration++;
    const { lat, lng, name } = event.params;
    this.#showConfirmMap(lat, lng, name);
  }

  clear() {
    // Same reasoning as #select: invalidates a reverse-lookup in flight for
    // the location being cleared.
    this.dragGeneration++;
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

  async #fetchSuggestions(query, generation) {
    let response;
    try {
      response = await fetch(
        `/location_searches?q=${encodeURIComponent(query)}`,
        {
          headers: { Accept: "application/json" },
        },
      );
    } catch {
      if (generation !== this.searchGeneration) return;
      this.#renderMessage(this.searchUnavailableValue);
      return;
    }

    if (generation !== this.searchGeneration) return;

    if (!response.ok) {
      this.#renderMessage(this.searchUnavailableValue);
      return;
    }

    let results;
    try {
      results = await response.json();
    } catch {
      if (generation !== this.searchGeneration) return;
      this.#renderMessage(this.searchUnavailableValue);
      return;
    }

    if (generation !== this.searchGeneration) return;

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

    this.marker = L.marker([lat, lng], {
      draggable: this.canAnnotateValue,
    }).addTo(this.confirmMapInstance);
    this.marker.on("dragend", () => this.#onDrag());

    this.#submitForm();
  }

  async #onDrag() {
    const generation = ++this.dragGeneration;
    const { lat, lng } = this.marker.getLatLng();
    this.latTarget.value = lat;
    this.lngTarget.value = lng;
    // The old name belongs to the old coordinates. Fall back to the raw
    // position immediately so a failed or no-match lookup can't submit the
    // new coordinates under the previous place's name.
    const fallbackName = `${lat.toFixed(5)}, ${lng.toFixed(5)}`;
    this.nameTarget.value = fallbackName;
    this.displayTextTarget.textContent = fallbackName;

    try {
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
    } catch {
      // A dropped connection still means the dragged position is real and
      // has to save -- just under the coordinate fallback name set above.
      if (generation !== this.dragGeneration) return;
    }

    this.#submitForm();
  }

  // Picking a suggestion and then immediately dragging the pin (or any two
  // rapid changes) could otherwise have two PATCHes in flight together, with
  // no guarantee the server applies them in the order the user made the
  // changes. Queuing so the next submit's request isn't even sent until the
  // previous one's response has landed removes that race at its source:
  // each queued attempt still gets its own save/restore in the order it was
  // made, even if a later change is already queued behind it by the time
  // its response arrives.
  #submitForm() {
    const form = this.element.closest("form");
    const controllers = (form?.dataset.controller || "").split(/\s+/);
    if (!form || !controllers.includes("auto-submit-form")) return;

    const attempted = {
      lat: this.latTarget.value,
      lng: this.lngTarget.value,
      name: this.nameTarget.value,
    };

    this.submitQueue = (this.submitQueue ?? Promise.resolve()).then(() =>
      this.#performSubmit(form, attempted),
    );
  }

  #performSubmit(form, attempted) {
    return new Promise((resolve) => {
      const onSubmitEnd = (event) => {
        form.removeEventListener("turbo:submit-end", onSubmitEnd);
        // The controller can be gone by the time this fires (navigated
        // away, frame torn down) -- nothing left here to save or restore.
        if (this.element.isConnected) {
          if (event.detail.success) {
            this.savedState = attempted;
          } else {
            this.#restore(this.savedState);
          }
        }
        resolve();
      };
      form.addEventListener("turbo:submit-end", onSubmitEnd);
      form.requestSubmit();
    });
  }

  #restore(state) {
    this.latTarget.value = state.lat;
    this.lngTarget.value = state.lng;
    this.nameTarget.value = state.name;

    if (state.lat && state.lng) {
      this.displayTextTarget.textContent = state.name;
      this.displayTarget.classList.remove("hidden");
      this.searchTarget.classList.add("hidden");
    } else {
      this.displayTarget.classList.add("hidden");
      this.searchTarget.classList.remove("hidden");
    }
    this.confirmMapTarget.classList.add("hidden");
    this.confirmMapInstance?.remove();
    this.confirmMapInstance = null;
  }
}
