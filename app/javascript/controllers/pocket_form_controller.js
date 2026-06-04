import { Controller } from "@hotwired/stimulus";

export default class extends Controller {
  static targets = ["amountField", "tagSelect", "fillDirectionSection"];

  connect() {
    this.#toggle(this.tagSelectTarget.value !== "");
  }

  onTagChange() {
    this.#toggle(this.tagSelectTarget.value !== "");
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
