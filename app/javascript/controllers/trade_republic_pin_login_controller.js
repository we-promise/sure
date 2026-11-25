import { Controller } from "@hotwired/stimulus";

// Shows the phone number and PIN login form of a Trade Republic connection,
// the same way its QR login shows the QR code. Only one login runs at a
// time: the `alternative` targets (the QR login button, or for a new
// connection the whole Add a connection row) hide while the form is open,
// and the PIN login button hides while a QR login runs.
export default class extends Controller {
  static targets = ["button", "form", "alternative"];
  static values = { loginText: String, cancelText: String };

  toggle(event) {
    event.preventDefault();
    const show = this.formTarget.hidden;
    this.formTarget.hidden = !show;
    for (const alternative of this.alternativeTargets)
      alternative.hidden = show;
    if (this.hasButtonTarget) {
      this.buttonTarget.setAttribute("aria-expanded", String(show));
      // Like the QR login button, which reads Cancel QR login while its QR
      // code shows.
      const label = show ? this.cancelTextValue : this.loginTextValue;
      const span = this.buttonTarget.querySelector("span");
      if (label && span) span.textContent = label;
    }
    // Focus moves into the form, and back to the PIN login button when the
    // form closes with the Cancel inside it.
    if (show)
      this.formTarget
        .querySelector("input:not([type='hidden']):not([disabled])")
        ?.focus();
    else if (this.hasButtonTarget) this.buttonTarget.focus();
  }

  qrStarted() {
    if (this.hasButtonTarget) this.buttonTarget.hidden = true;
  }

  qrStopped() {
    if (this.hasButtonTarget) this.buttonTarget.hidden = false;
  }
}
