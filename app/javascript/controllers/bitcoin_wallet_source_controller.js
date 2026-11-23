import { Controller } from "@hotwired/stimulus";

// Shows the verification address and advanced settings only once an
// account-level xpub/zpub has been pasted; a plain address needs neither.
export default class extends Controller {
  static targets = ["key", "hdFields"];

  connect() {
    this.toggle();
  }

  toggle() {
    const hd = /^[xz]pub/.test(this.keyTarget.value.trim());
    this.hdFieldsTarget.hidden = !hd;
    for (const input of this.hdFieldsTarget.querySelectorAll("input")) {
      input.disabled = !hd;
    }
  }
}
