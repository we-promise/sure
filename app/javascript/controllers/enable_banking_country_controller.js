import { Controller } from "@hotwired/stimulus";

// Carries the country picked in the Enable Banking settings form (saved or
// not) into the "Add Connection" request.
export default class extends Controller {
  static targets = ["select"];

  applyCountry(event) {
    if (!this.hasSelectTarget || !this.selectTarget.value) return;

    const field = event.target.querySelector('input[name="country_code"]');
    if (field) field.value = this.selectTarget.value;
  }
}
