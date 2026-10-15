import { Controller } from "@hotwired/stimulus";

// Shows the phone number and PIN login form below a Trade Republic
// connection, the same way its QR login shows the QR code.
export default class extends Controller {
  static targets = ["button", "form"];

  toggle(event) {
    event.preventDefault();
    const show = this.formTarget.hidden;
    this.formTarget.hidden = !show;
    this.buttonTarget.setAttribute("aria-expanded", String(show));
    if (show)
      this.formTarget
        .querySelector("input:not([type='hidden']):not([disabled])")
        ?.focus();
  }
}
