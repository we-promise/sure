import { Controller } from "@hotwired/stimulus";

// Updates the date preview text when the QIF date format dropdown changes.
// Previews are precomputed server-side and passed as a JSON value.
export default class extends Controller {
  static targets = ["preview"];
  static values = { previews: Object };

  change(event) {
    const format = event.target.value;
    const date = this.previewsValue[format];

    this.previewTarget.textContent = date || "";
  }
}
