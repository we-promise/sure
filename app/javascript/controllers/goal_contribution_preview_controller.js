import { Controller } from "@hotwired/stimulus";

// Live impact preview for the add-contribution modal. Reads current
// balance + target amount from values and updates a preview sentence
// each keystroke. Template strings come from ERB so the wording stays
// localized.
export default class extends Controller {
  static targets = ["amountInput", "preview"];
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
      return new Intl.NumberFormat(undefined, {
        style: "currency",
        currency: this.currencyValue || "USD",
        maximumFractionDigits: 0,
      }).format(value);
    } catch {
      return `${this.currencyValue || "$"}${Math.round(value).toLocaleString()}`;
    }
  }
}
