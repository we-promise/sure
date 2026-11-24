import { Controller } from "@hotwired/stimulus";

// A one-off is paid once, in its start year, and has no end year. Its To year
// field is hidden and disabled, not cleared: a disabled input is left out of
// the submission, so a stale value cannot be refused as ending before the
// stream starts, and switching back to another kind restores what was typed.
export default class extends Controller {
  static targets = ["kind", "endYearField"];

  connect() {
    this.refresh();
  }

  refresh() {
    const oneOff = this.kindTarget.value === "one_off";

    this.endYearFieldTargets.forEach((field) => {
      field.classList.toggle("hidden", oneOff);
      field.querySelectorAll("input").forEach((input) => {
        input.disabled = oneOff;
      });
    });
  }
}
