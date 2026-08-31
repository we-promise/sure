import { Controller } from "@hotwired/stimulus";
import { CurrenciesService } from "services/currencies_service";
import parseLocaleFloat from "utils/parse_locale_float";

// Connects to data-controller="money-field"
// when currency select change, update the input value with the correct placeholder and step
export default class extends Controller {
  static targets = ["amount", "currency", "symbol"];
  static values = {
    precision: Number,
    step: String,
  };

  requestSequence = 0;

  handleCurrencyChange(e) {
    const selectedCurrency = e.target.value;
    this.updateAmount(selectedCurrency);
  }

  updateAmount(currency) {
    const requestId = ++this.requestSequence;
    new CurrenciesService().get(currency).then((currencyData) => {
      if (requestId !== this.requestSequence) return;

      this.amountTarget.step =
        this.hasStepValue &&
        this.stepValue !== "" &&
        (this.stepValue === "any" || Number.isFinite(Number(this.stepValue)))
          ? this.stepValue
          : currencyData.step;

      const rawValue = this.amountTarget.value.trim();
      if (rawValue !== "") {
        const parsedAmount = parseLocaleFloat(rawValue);
        if (Number.isFinite(parsedAmount)) {
          const precision =
            this.hasPrecisionValue && Number.isInteger(this.precisionValue)
              ? this.precisionValue
              : currencyData.default_precision;
          this.amountTarget.value = parsedAmount.toFixed(precision);
        }
      }

      this.symbolTarget.innerText = currencyData.symbol;
    }).catch(() => {
      // Catch prevents Unhandled Promise Rejection for network failures.
      // Silently ignored as they are unactionable by the user.
    });
  }

  // Number inputs silently reject pasted formatted values ("20,000 ",
  // "1.234,56"), leaving the field blank. Intercept the paste, parse the
  // locale format, and insert the plain number instead so copy/paste from
  // statements and spreadsheets just works.
  pasteAmount(event) {
    const text = (event.clipboardData || window.clipboardData)?.getData("text")?.trim() ?? "";
    if (text === "") return;

    const parsed = parseLocaleFloat(text);
    if (!Number.isFinite(parsed)) return;

    event.preventDefault();
    const precision =
      this.hasPrecisionValue && Number.isInteger(this.precisionValue)
        ? this.precisionValue
        : 2;
    this.amountTarget.value = parsed.toFixed(precision);
    // Let auto-submit / validation listeners know the value changed.
    this.amountTarget.dispatchEvent(new Event("input", { bubbles: true }));
  }
}
