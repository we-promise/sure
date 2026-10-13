import { Controller } from "@hotwired/stimulus";

// Add and remove rate-change rows, and show the section only for a loan whose
// rate can actually move.
//
// Rows are plain inputs named as an array, so the form submits and the server
// reads them with no JavaScript at all — this controller saves a round trip
// per row and keeps the section honest about whether it applies.
//
// Hidden means DISABLED, not merely invisible. A disabled input is not
// submitted, so a fixed-rate loan sends no `rate_changes` key at all and its
// recorded changes are retained rather than cleared. The server renders the
// section already hidden and disabled for a fixed loan, retained rows
// included, so this holds without JavaScript too; `toggle()` only follows the
// select from there. Switching to variable enables the retained rows, and the
// next save resubmits them rather than the bare sentinel that would clear them.
export default class extends Controller {
  static targets = ["rows", "template", "empty", "section", "rateType"];
  // The one rate type that cannot move. Anything else non-blank is variable,
  // the same reading as Loan#variable_rate_type?, so a provider-written value
  // such as "arm" keeps its editor rather than being hidden by a list the
  // form never offered it in.
  static values = { fixedType: String };

  connect() {
    this.toggle();
  }

  add(event) {
    event.preventDefault();
    const row = this.templateTarget.content.firstElementChild.cloneNode(true);
    this.rowsTarget.appendChild(row);
    row.querySelector("input[type='date']")?.focus();
    this.#sync();
  }

  remove(event) {
    event.preventDefault();
    event.target.closest("[data-rate-change-row]")?.remove();
    this.#sync();
  }

  toggle() {
    const rateType = this.rateTypeTarget?.value ?? "";
    const applies = rateType !== "" && rateType !== this.fixedTypeValue;
    this.sectionTarget.hidden = !applies;
    for (const el of this.sectionTarget.querySelectorAll(
      "input, select, button",
    )) {
      el.disabled = !applies;
    }
    this.#sync();
  }

  #sync() {
    if (this.hasEmptyTarget) {
      this.emptyTarget.hidden = this.rowsTarget.children.length > 0;
    }
  }
}
