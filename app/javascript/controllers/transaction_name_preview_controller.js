import { Controller } from "@hotwired/stimulus";

// Preview the server-side fallback without changing the submitted name.
export default class extends Controller {
  static targets = ["name"];

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
}
