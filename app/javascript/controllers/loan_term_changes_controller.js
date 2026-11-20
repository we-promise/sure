import { Controller } from "@hotwired/stimulus";

// Add and remove term-change rows on the loan form.
//
// Rows are plain inputs named as an array, so the form submits and the server
// reads them with no JavaScript at all; this controller saves a round trip per
// row.
export default class extends Controller {
  static targets = ["rows", "template", "empty", "add"];

  add(event) {
    event.preventDefault();
    const row = this.templateTarget.content.firstElementChild.cloneNode(true);
    this.rowsTarget.appendChild(row);
    row.querySelector("input[type='date']")?.focus();
    this.#sync();
  }

  remove(event) {
    event.preventDefault();
    // The form sits in a dialog that closes on a click outside its content.
    // Once the row is gone the button is outside it, so the click stops here.
    event.stopPropagation();
    event.target.closest("[data-term-change-row]")?.remove();
    // The removed button had the focus.
    this.addTarget.focus();
    this.#sync();
  }

  #sync() {
    this.emptyTarget.hidden = this.rowsTarget.children.length > 0;
  }
}
