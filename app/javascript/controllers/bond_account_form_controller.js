import { Controller } from "@hotwired/stimulus";

export default class extends Controller {
  static targets = ["wrapperSelect", "taxExemptFields"];
  static values = { taxExemptWrappers: Array };

  connect() {
    this.toggleTaxWrapperFields();
  }

  toggleTaxWrapperFields() {
    const wrapper = this.wrapperSelectTarget.value;
    const enabled = this.taxExemptWrappersValue.includes(wrapper);

    this.taxExemptFieldsTargets.forEach((element) => {
      element.classList.toggle("hidden", !enabled);
      element.querySelectorAll("input").forEach((input) => {
        if (input.type === "checkbox") {
          input.checked = enabled ? input.checked : false;
        }
      });
    });
  }
}