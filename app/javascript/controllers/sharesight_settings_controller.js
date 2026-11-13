import { Controller } from "@hotwired/stimulus";

// Only shows the Sharesight settings that matter for the chosen cash and
// dividend options. Hidden fields keep their values.
export default class extends Controller {
  static targets = ["cashMode", "dividendMode", "section"];

  connect() {
    this.update();
  }

  update() {
    const cashMode = this.cashModeTarget.value;
    const dividendMode = this.dividendModeTarget.value;

    for (const section of this.sectionTargets) {
      const cashModes = section.dataset.cashModes?.split(" ");
      const dividendModes = section.dataset.dividendModes?.split(" ");
      const visible =
        (!cashModes || cashModes.includes(cashMode)) &&
        (!dividendModes || dividendModes.includes(dividendMode));

      section.classList.toggle("hidden", !visible);
    }
  }
}
