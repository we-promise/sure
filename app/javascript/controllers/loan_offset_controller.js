import { Controller } from "@hotwired/stimulus";

export default class extends Controller {
  // `rateChanges` shares this controller because it is revealed by the same
  // condition -- the rate type being one that can move -- and a second
  // controller toggling on the same input would duplicate the listener rather
  // than the intent.
  static targets = ["rateType", "offsetAccounts", "rateChanges"];

  // Supplied by the form from Loan::VARIABLE_RATE_TYPES. Not hardcoded here:
  // the server decides which rate types schedule off the variable path, and a
  // second copy of that list in JavaScript is a copy that goes stale.
  static values = { variableRateTypes: { type: Array, default: ["variable"] } };

  connect() {
    this.update();
  }

  update() {
    const visible = this.variableRateTypesValue.includes(
      this.rateTypeTarget.value,
    );
    this.offsetAccountsTarget.classList.toggle("hidden", !visible);
    this.offsetAccountsTarget.toggleAttribute("aria-hidden", !visible);

    if (this.hasRateChangesTarget) {
      this.rateChangesTarget.classList.toggle("hidden", !visible);
      this.rateChangesTarget.toggleAttribute("aria-hidden", !visible);
      // Hiding a field does not stop it being submitted. Without this, a row
      // edited and then hidden by switching to a fixed rate type is still
      // posted, and the server assembles it into the schedule -- an edit the
      // user can no longer see, resurfacing when the rate can move again.
      // Disabling is deliberately not clearing: the rows the loan already has
      // are its rate history, and switching rate type must not silently
      // discard them.
      for (const element of this.rateChangesTarget.querySelectorAll(
        "input, button, select, textarea",
      )) {
        element.disabled = !visible;
      }
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
