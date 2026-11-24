import { Controller } from "@hotwired/stimulus";

// A one-off is paid once, in its start year, and has no end year. Its To year
// field is hidden and disabled, not cleared, so switching back to another
// kind restores what was typed; an empty end year is enabled in its place, so
// a one-off always saves without one, even one edited from a stream that had
// one. Only one of the two is ever submitted.
export default class extends Controller {
  static targets = ["kind", "endYearField", "noEndYear"];

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

    this.noEndYearTargets.forEach((input) => {
      input.disabled = !oneOff;
    });
  }
}
