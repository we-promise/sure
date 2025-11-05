import { Controller } from "@hotwired/stimulus";

// Submits a form when the input is confirmed (Enter) or when the field loses focus.
// Usage:
// <form data-controller="auto-submit" data-action="keydown.enter->auto-submit#submit blur->auto-submit#submit">
//   <input data-auto-submit-target="input" ... />
// </form>
export default class extends Controller {
  static targets = ["input"]; 

  submit(event) {
    const form = this.element;
    // Ignore empty values to avoid accidental POST noise
    if (this.hasInputTarget && !this.inputTarget.value) return;

    // Prevent double submits on repeated Enter
    if (this.submitting) return;
    this.submitting = true;

    // Let Turbo handle the submission
    try {
      form.requestSubmit();
    } finally {
      // allow subsequent attempts after a short tick
      setTimeout(() => (this.submitting = false), 150);
    }
  }
}
