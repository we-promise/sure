import { Controller } from "@hotwired/stimulus";

// Two related jobs for the (optional) transaction name field:
//
// 1. Live-updates its placeholder to preview what the server-side fallback
//    (Entry#set_default_name) will save if the field is left blank: category,
//    then merchant. Only ever touches the placeholder, never the field's
//    value, so it can't clobber anything the user typed -- and since
//    placeholders aren't submitted, the preview can never drift from what
//    actually gets saved as long as both follow the same order. There is no
//    generic fallback for "neither is set": the field's original hint text
//    comes back instead, since a name is still required in that case.
//
// 2. A custom suggestion dropdown for recently used names, filtered as the
//    user types. This exists instead of a native <datalist> because iOS
//    Safari doesn't render datalist suggestions for text inputs at all --
//    a plain <datalist> works on desktop but is silently a no-op there.
export default class extends Controller {
  static targets = ["name", "suggestions", "suggestionOption"];

  connect() {
    if (this.hasNameTarget) this.originalPlaceholder = this.nameTarget.placeholder;
  }

  update() {
    if (!this.hasNameTarget) return;

    this.nameTarget.placeholder = this.previewName() || this.originalPlaceholder;
  }

  previewName() {
    const parts = [
      this.selectionText("category-select", '[data-testid="category-name"]'),
      this.selectionText("merchant-select", "[data-merchant-select-name]"),
    ].filter(Boolean);

    return parts.length > 0 ? parts.join(" - ") : null;
  }

  // `nameSelector` picks out just the label text within the cloned
  // selection markup -- reading the container's full textContent would
  // also pick up the letter-avatar glyph (e.g. "A" for a logo-less
  // merchant) or other decorative text nodes alongside the real name.
  selectionText(controllerName, nameSelector) {
    const hiddenInput = this.element.querySelector(
      `[data-controller~="${controllerName}"] [data-${controllerName}-target="hiddenInput"]`,
    );
    if (!hiddenInput || !hiddenInput.value) return null;

    const container = this.element.querySelector(
      `[data-controller~="${controllerName}"] [data-${controllerName}-target="selectionContainer"]`,
    );
    const text = container?.querySelector(nameSelector)?.textContent.trim();
    return text || null;
  }

  showSuggestions() {
    this.filterSuggestions();
  }

  filterSuggestions() {
    if (!this.hasSuggestionsTarget) return;

    const query = this.nameTarget.value.trim().toLowerCase();
    let anyVisible = false;

    this.suggestionOptionTargets.forEach((option) => {
      const matches = option.dataset.name.toLowerCase().includes(query);
      option.classList.toggle("hidden", !matches);
      if (matches) anyVisible = true;
    });

    this.suggestionsTarget.classList.toggle("hidden", !anyVisible);
  }

  // Hiding on a delay (rather than immediately on blur) lets the
  // mousedown-based selectSuggestion below still register as a click on
  // the option before it disappears.
  scheduleHideSuggestions() {
    if (!this.hasSuggestionsTarget) return;

    this.hideTimeout = setTimeout(() => {
      this.suggestionsTarget.classList.add("hidden");
    }, 150);
  }

  selectSuggestion(event) {
    event.preventDefault();
    if (this.hideTimeout) clearTimeout(this.hideTimeout);

    this.nameTarget.value = event.currentTarget.dataset.name;
    this.suggestionsTarget.classList.add("hidden");
    this.nameTarget.focus();
  }
}
