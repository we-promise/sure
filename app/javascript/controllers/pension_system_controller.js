import { Controller } from "@hotwired/stimulus";

// Toggles visibility of country-specific pension field groups
// based on the selected pension system.
//
// Usage:
//   <div data-controller="pension-system">
//     <select data-pension-system-target="select" data-action="change->pension-system#toggle">
//     <div data-pension-system-target="fields" data-pension-system-key="de_grv"> ... </div>
//     <div data-pension-system-target="fields" data-pension-system-key="us_ss"> ... </div>
//   </div>
export default class extends Controller {
  static targets = ["select", "fields"];

  connect() {
    this.toggle();
  }

  toggle() {
    const selected = this.selectTarget.value;

    this.fieldsTargets.forEach((el) => {
      if (el.dataset.pensionSystemKey === selected) {
        el.classList.remove("hidden");
        el.querySelectorAll("input, select").forEach((i) => (i.disabled = false));
      } else {
        el.classList.add("hidden");
        el.querySelectorAll("input, select").forEach((i) => (i.disabled = true));
      }
    });
  }
}
