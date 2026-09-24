import { Controller } from "@hotwired/stimulus";

// Clears an input's value from an external button. Dispatches both
// "change" and "blur" so it fires regardless of the field's auto-submit
// trigger event.
export default class extends Controller {
  static targets = ["input"];

  clear() {
    this.inputTarget.value = "";
    this.inputTarget.dispatchEvent(new Event("change", { bubbles: true }));
    this.inputTarget.dispatchEvent(new Event("blur"));
  }
}
