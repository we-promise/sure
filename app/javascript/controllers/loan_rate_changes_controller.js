import { Controller } from "@hotwired/stimulus";

// Repeatable {effective date, rate} rows for a variable-rate loan.
//
// The rows are plain inputs submitted as `rate_changes` and assembled into the
// schedule server-side -- the jsonb column is not mass-assignable, so there is
// nothing here that constructs JSON.
//
// Removal marks a hidden `_destroy` field and hides the row rather than
// detaching it, so a row removed by mistake is still in the DOM for the server
// to ignore, and the indices of the remaining rows do not shift under the user.
export default class extends Controller {
  static targets = ["rows", "template", "row"];

  add(event) {
    event.preventDefault();
    const markup = this.templateTarget.innerHTML.replaceAll(
      "NEW_RECORD",
      new Date().getTime().toString(),
    );
    this.rowsTarget.insertAdjacentHTML("beforeend", markup);
  }

  remove(event) {
    event.preventDefault();
    const row = event.target.closest("[data-loan-rate-changes-target='row']");
    if (!row) return;

    row.querySelector("input[name*='_destroy']").value = "1";
    row.classList.add("hidden");
    // Removed rows must not carry values the server would otherwise assemble.
    row
      .querySelectorAll("input[type='date'], input[type='number']")
      .forEach((input) => {
        input.value = "";
      });
  }
}
