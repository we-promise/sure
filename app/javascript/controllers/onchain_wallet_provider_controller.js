import { Controller } from "@hotwired/stimulus";

export default class extends Controller {
  static targets = ["field", "segment", "mobileSelect", "etherscanFields"];
  static values = { active: String };

  connect() {
    this.sync();
  }

  activeValueChanged() {
    this.sync();
  }

  select(event) {
    const el = event.currentTarget;
    const provider = el.dataset.provider || el.value;
    if (!provider) return;

    this.activeValue = provider;
  }

  sync() {
    if (!this.activeValue) return;

    if (this.hasFieldTarget) this.fieldTarget.value = this.activeValue;

    if (this.hasMobileSelectTarget) {
      this.mobileSelectTarget.value = this.activeValue;
    }

    this.segmentTargets.forEach((segment) => {
      const selected = segment.dataset.provider === this.activeValue;
      segment.classList.toggle("segmented-control__segment--active", selected);
      segment.setAttribute("aria-pressed", selected.toString());
    });

    this.etherscanFieldsTargets.forEach((field) => {
      field.hidden = this.activeValue !== "etherscan";
    });
  }
}
