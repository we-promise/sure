import { Controller } from "@hotwired/stimulus";

// Connects to data-controller="rule--split-action"
// Split rows use real, individually-named form fields (rendered server-side), so this
// controller only handles adding/removing rows and the live percentage-sum indicator —
// it never needs to serialize anything into a hidden field itself.
export default class extends Controller {
  static targets = ["row", "rowTemplate", "rowsContainer", "summary", "modeRadio", "shareInput", "fixedModeHint"];

  static MIN_ROWS = 2;
  static AMOUNT_TOLERANCE = 0.01;

  connect() {
    this.updateSummary();
  }

  get mode() {
    const checked = this.modeRadioTargets.find((radio) => radio.checked);
    return checked ? checked.value : "percentage";
  }

  addRow(e) {
    e.preventDefault();
    // Without this, the click bubbles up to the dialog's "click outside to close"
    // listener and (harmlessly on its own) counts as an outside click.
    e.stopPropagation();

    const html = this.rowTemplateTarget.innerHTML.replaceAll(
      "ROW_IDX_PLACEHOLDER",
      Date.now(),
    );
    this.rowsContainerTarget.insertAdjacentHTML("beforeend", html);
    this.updateSummary();
  }

  removeRow(e) {
    e.preventDefault();
    // Critical here: this handler removes the clicked element from the DOM. Without
    // stopPropagation, the click event keeps bubbling to the dialog's "click outside to
    // close" listener, which checks whether e.target is still contained in the dialog —
    // but the target we just removed no longer is, so the whole "New rule" dialog would
    // incorrectly close itself.
    e.stopPropagation();

    if (this.rowTargets.length <= this.constructor.MIN_ROWS) return;

    e.target.closest("[data-rule--split-action-target='row']").remove();
    this.updateSummary();
  }

  updateSummary() {
    if (this.hasFixedModeHintTarget) {
      this.fixedModeHintTarget.classList.toggle("hidden", this.mode !== "fixed");
    }

    const total = this.shareInputTargets.reduce(
      (sum, input) => sum + (Number.parseFloat(input.value) || 0),
      0,
    );

    if (this.mode === "percentage") {
      const balanced = Math.abs(total - 100) < this.constructor.AMOUNT_TOLERANCE;
      this.summaryTarget.textContent = `${total.toFixed(2)}%`;
      this.summaryTarget.classList.toggle("text-destructive", !balanced);
      this.summaryTarget.classList.toggle("text-success", balanced);
      return;
    }

    // Fixed mode: compare the summed shares against the rule's "Amount equal to X"
    // condition (if one is set), since that's the only thing that guarantees every
    // matching transaction has the same total the shares need to sum to.
    const targetAmount = this.#findExactAmountConditionValue();

    if (targetAmount === null) {
      this.summaryTarget.textContent = total.toFixed(2);
      this.summaryTarget.classList.remove("text-destructive", "text-success");
      return;
    }

    const balanced = Math.abs(total - targetAmount) < this.constructor.AMOUNT_TOLERANCE;
    this.summaryTarget.textContent = `${total.toFixed(2)} / ${targetAmount.toFixed(2)}`;
    this.summaryTarget.classList.toggle("text-destructive", !balanced);
    this.summaryTarget.classList.toggle("text-success", balanced);
  }

  // Looks across the whole form (not just this controller's element) for a
  // non-deleted "transaction amount = X" condition and returns its numeric value,
  // or null if no such condition currently exists.
  #findExactAmountConditionValue() {
    const conditionRows = document.querySelectorAll("[data-controller~='rule--conditions']");

    for (const row of conditionRows) {
      if (row.classList.contains("hidden")) continue;

      const typeSelect = row.querySelector("select[name*='[condition_type]']");
      const operatorSelect = row.querySelector("select[name*='[operator]']");
      if (typeSelect?.value !== "transaction_amount" || operatorSelect?.value !== "=") continue;

      const valueInput = row.querySelector("[name*='[value]']");
      const amount = Number.parseFloat(valueInput?.value);
      if (Number.isFinite(amount)) return amount;
    }

    return null;
  }
}
