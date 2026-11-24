import { Controller } from "@hotwired/stimulus";

// A one-off is paid once, in its start year, and has no end year. Hiding the
// To year field for one, and clearing it, keeps a stale value from being
// submitted and refused as ending before the stream starts.
export default class extends Controller {
  static targets = ["kind", "endYearField"];

  connect() {
    this.refresh();
  }

  refresh() {
    const oneOff = this.kindTarget.value === "one_off";

    this.endYearFieldTargets.forEach((field) => {
      field.classList.toggle("hidden", oneOff);
      if (!oneOff) return;

      field.querySelectorAll("input").forEach((input) => {
        input.value = "";
      });
    });
  }
}
