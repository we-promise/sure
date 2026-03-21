import { Controller } from "@hotwired/stimulus";

// Connects to data-controller="import-file"
export default class extends Controller {
  static targets = ["input"];

  open() {
    this.inputTarget.click();
  }

  submit() {
    if (this.inputTarget.files.length > 0) {
      this.inputTarget.closest("form").requestSubmit();
    }
  }
}
