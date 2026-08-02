import { Controller } from "@hotwired/stimulus";

export default class extends Controller {
  static targets = ["amountField", "tagRadio", "fillDirectionSection"];

  connect() {
    this.#toggle(this.#selectedTagId() !== "");
  }

  onTagChange() {
    this.#toggle(this.#selectedTagId() !== "");
  }

  #selectedTagId() {
    return this.tagRadioTargets.find(r => r.checked)?.value ?? "";
  }

  #toggle(hasTag) {
    const input = this.amountFieldTarget.querySelector("input");
    if (input) input.disabled = hasTag;
    this.amountFieldTarget.style.opacity = hasTag ? "0.5" : "1";
    this.amountFieldTarget.style.pointerEvents = hasTag ? "none" : "";

    if (this.hasFillDirectionSectionTarget) {
      this.fillDirectionSectionTarget.classList.toggle("hidden", !hasTag);
    }
  }
}
