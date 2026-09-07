import { Controller } from "@hotwired/stimulus";

export default class extends Controller {
  // `rateChanges` shares this controller because it is revealed by the same
  // condition -- rate_type being "variable" -- and a second controller toggling
  // on the same input would duplicate the listener rather than the intent.
  static targets = ["rateType", "offsetAccounts", "rateChanges"];

  connect() {
    this.update();
  }

  update() {
    const visible = this.rateTypeTarget.value === "variable";
    this.offsetAccountsTarget.classList.toggle("hidden", !visible);
    this.offsetAccountsTarget.toggleAttribute("aria-hidden", !visible);

    if (this.hasRateChangesTarget) {
      this.rateChangesTarget.classList.toggle("hidden", !visible);
      this.rateChangesTarget.toggleAttribute("aria-hidden", !visible);
    }

    if (!visible) {
      this.offsetAccountsTarget
        .querySelector("select")
        ?.selectedOptions.forEach((option) => {
          option.selected = false;
        });
    }
  }
}
