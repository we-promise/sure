import { Controller } from "@hotwired/stimulus";

export default class extends Controller {
  static targets = ["dialog", "checkbox"];
  static values = {
    baseCurrency: String,
  };

  open() {
    this.dialogTarget.showModal();
  }

  selectAll() {
    this.checkboxTargets.forEach((checkbox) => {
      checkbox.checked = true;
    });
  }

  selectBaseOnly() {
    this.checkboxTargets.forEach((checkbox) => {
      checkbox.checked = checkbox.value === this.baseCurrencyValue;
    });
  }

  handleSubmitEnd(event) {
    if (!event.detail.success) return;
    if (!this.dialogTarget.open) return;

    this.dialogTarget.close();
  }
}
