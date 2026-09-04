import { Controller } from "@hotwired/stimulus";

// Live-updates the transaction name field's placeholder to preview what the
// server-side fallback (Entry#set_default_name) will save if the field is
// left blank: merchant, then category, then a generic label. Only ever
// touches the placeholder, never the field's value, so it can't clobber
// anything the user typed -- and since placeholders aren't submitted, the
// preview can never drift from what actually gets saved as long as both
// follow the same fallback order.
export default class extends Controller {
  static targets = ["name"];
  static values = { unknownLabel: String };

  update() {
    if (!this.hasNameTarget) return;

    this.nameTarget.placeholder = this.previewName();
  }

  previewName() {
    const parts = [
      this.selectionText("merchant-select"),
      this.selectionText("category-select"),
    ].filter(Boolean);

    return parts.length > 0 ? parts.join(" - ") : this.unknownLabelValue;
  }

  selectionText(controllerName) {
    const hiddenInput = this.element.querySelector(
      `[data-controller~="${controllerName}"] [data-${controllerName}-target="hiddenInput"]`,
    );
    if (!hiddenInput || !hiddenInput.value) return null;

    const container = this.element.querySelector(
      `[data-controller~="${controllerName}"] [data-${controllerName}-target="selectionContainer"]`,
    );
    const text = container?.textContent.trim();
    return text || null;
  }
}
