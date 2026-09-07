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

  // Clones the <template> element's content rather than parsing its innerHTML.
  // Nothing here is user input, but building DOM from a string is the shape of
  // an injection bug, and cloneNode is what <template> is for.
  add(event) {
    event.preventDefault();

    const row = this.templateTarget.content.cloneNode(true);
    const suffix = Date.now().toString();

    row.querySelectorAll("[id], [for]").forEach((element) => {
      if (element.id) element.id = element.id.replace("NEW_RECORD", suffix);
      const target = element.getAttribute("for");
      if (target)
        element.setAttribute("for", target.replace("NEW_RECORD", suffix));
    });

    this.rowsTarget.appendChild(row);
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
