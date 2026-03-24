import { Controller } from "@hotwired/stimulus";

// Handles keyboard interaction in the Quick Categorize wizard.
// When the user presses Enter in the category filter field, the first
// visible category pill is clicked, submitting the form.
export default class extends Controller {
  static targets = ["list"];

  selectFirst(event) {
    if (event.key !== "Enter") return;
    event.preventDefault();

    const first = Array.from(
      this.listTarget.querySelectorAll(".filterable-item")
    ).find((el) => el.style.display !== "none");

    first?.click();
  }
}
