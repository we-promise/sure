import { Controller } from "@hotwired/stimulus";

// Live impact preview for the record-pledge modal. Reads current balance +
// target amount from values and updates a preview sentence each keystroke.
// Template strings come from ERB so the wording stays localized.
export default class extends Controller {
  static targets = [
    "amountInput",
    "preview",
    "accountSelect",
    "helperConnected",
    "helperManual",
  ];
  static values = {
    currentBalance: Number,
    targetAmount: Number,
    currency: String,
    templateZero: String,
    templateNonzero: String,
    templateReached: String,
  };

  connect() {
    this.update();
    this.accountChanged();
  }

  // Helper text reacts to the currently-selected account, not the goal as a
  // whole. A mixed-funding goal (one connected account + one manual) used to
  // paint the "connected" helper even if the user then picked the manual
  // account from the dropdown; the saved pledge would be `kind: manual_save`
  // (correct, per `kind_for_account` in the controller) but the helper read
  // "transfer-style" copy until submission.
  accountChanged() {
    if (!this.hasAccountSelectTarget) return;
    if (!this.hasHelperConnectedTarget || !this.hasHelperManualTarget) return;
    const opt = this.accountSelectTarget.selectedOptions[0];
    const isManual = opt?.dataset.manual === "true";
    this.helperConnectedTarget.hidden = isManual;
    this.helperManualTarget.hidden = !isManual;
  }

  update() {
    if (!this.hasPreviewTarget) return;

    const amount = this.#amountValue();
    const newTotal = this.currentBalanceValue + amount;
    const target = this.targetAmountValue;
    const reached = newTotal >= target && target > 0;
    const percent = target > 0 ? Math.min(100, Math.round((newTotal / target) * 100)) : 0;

    let text;
    if (reached) {
      text = this.templateReachedValue.replace("{target}", this.#money(target));
    } else if (amount === 0) {
      text = this.templateZeroValue
        .replaceAll("{percent}", percent.toString())
        .replaceAll("{current}", this.#money(this.currentBalanceValue))
        .replaceAll("{target}", this.#money(target));
    } else {
      text = this.templateNonzeroValue
        .replaceAll("{percent}", percent.toString())
        .replaceAll("{newTotal}", this.#money(newTotal))
        .replaceAll("{target}", this.#money(target));
    }

    this.previewTarget.textContent = text;
  }

  #amountValue() {
    if (!this.hasAmountInputTarget) return 0;
    const parsed = Number.parseFloat(this.amountInputTarget.value);
    return Number.isFinite(parsed) && parsed > 0 ? parsed : 0;
  }

  #money(value) {
    try {
      // Let Intl pick the currency-specific default fraction digits so
      // USD/EUR previews show cents while JPY/KRW stay whole-unit. The
      // server saves the user-entered amount verbatim; the preview must
      // not silently round it.
      return new Intl.NumberFormat(undefined, {
        style: "currency",
        currency: this.currencyValue || "USD",
      }).format(value);
    } catch {
      return `${this.currencyValue || "$"}${value.toLocaleString()}`;
    }
  }
}
