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
// 2. A keyboard- and mouse-accessible suggestion dropdown for recently used
//    names, filtered as the user types (an ARIA combobox: the input keeps
//    focus throughout, arrow keys move an active-descendant highlight,
//    Enter/click applies it). This exists instead of a native <datalist>
//    because iOS Safari doesn't render datalist suggestions for text inputs
//    at all -- a plain <datalist> works on desktop but is silently a no-op
//    there.
export default class extends Controller {
  static targets = ["name", "suggestions", "suggestionOption"];

  connect() {
    if (this.hasNameTarget) this.originalPlaceholder = this.nameTarget.placeholder;
    this.activeIndex = -1;
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

    this.activeIndex = -1;
    this.suggestionsTarget.classList.toggle("hidden", !anyVisible);
    this.nameTarget.setAttribute("aria-expanded", anyVisible ? "true" : "false");
  }

  // Hiding on a delay (rather than immediately on blur) lets the
  // mousedown-based selectSuggestion below still register as a click on
  // the option before it disappears.
  scheduleHideSuggestions() {
    if (!this.hasSuggestionsTarget) return;

    this.hideTimeout = setTimeout(() => {
      this.suggestionsTarget.classList.add("hidden");
      this.activeIndex = -1;
      this.nameTarget.setAttribute("aria-expanded", "false");
      this.nameTarget.removeAttribute("aria-activedescendant");
    }, 150);
  }

  // Arrow keys move a highlighted "active descendant" without moving DOM
  // focus off the input (so typing keeps working); Enter applies whichever
  // option is highlighted; Escape closes the list.
  handleKeydown(event) {
    if (!this.hasSuggestionsTarget || this.suggestionsTarget.classList.contains("hidden")) return;

    const visible = this.visibleSuggestions;
    if (visible.length === 0) return;

    if (event.key === "ArrowDown") {
      event.preventDefault();
      this.activeIndex = (this.activeIndex + 1) % visible.length;
      this.highlightActive(visible);
    } else if (event.key === "ArrowUp") {
      event.preventDefault();
      this.activeIndex = (this.activeIndex - 1 + visible.length) % visible.length;
      this.highlightActive(visible);
    } else if (event.key === "Enter" && this.activeIndex >= 0) {
      event.preventDefault();
      this.applySuggestion(visible[this.activeIndex]);
    } else if (event.key === "Escape") {
      this.suggestionsTarget.classList.add("hidden");
      this.activeIndex = -1;
      this.nameTarget.setAttribute("aria-expanded", "false");
      this.nameTarget.removeAttribute("aria-activedescendant");
    }
  }

  get visibleSuggestions() {
    return this.suggestionOptionTargets.filter((option) => !option.classList.contains("hidden"));
  }

  highlightActive(visible) {
    visible.forEach((option, index) => {
      const active = index === this.activeIndex;
      option.classList.toggle("bg-container-inset", active);
      option.setAttribute("aria-selected", active ? "true" : "false");
    });

    const activeOption = visible[this.activeIndex];
    if (!activeOption) return;

    activeOption.scrollIntoView({ block: "nearest" });
    this.nameTarget.setAttribute("aria-activedescendant", activeOption.id);
  }

  selectSuggestion(event) {
    event.preventDefault();
    if (this.hideTimeout) clearTimeout(this.hideTimeout);

    this.applySuggestion(event.currentTarget);
  }

  applySuggestion(option) {
    this.nameTarget.value = option.dataset.name;
    this.suggestionsTarget.classList.add("hidden");
    this.activeIndex = -1;
    this.nameTarget.setAttribute("aria-expanded", "false");
    this.nameTarget.removeAttribute("aria-activedescendant");
    this.nameTarget.focus();
  }
}
