import { Controller } from "@hotwired/stimulus";
import parseLocaleFloat from "utils/parse_locale_float";
import { CurrenciesService } from "services/currencies_service";

// Connects to data-controller="money-field"
// when currency select change, update the input value with the correct placeholder and step
export default class extends Controller {
  static targets = ["amount", "currency", "symbol"];

  handleCurrencyChange(e) {
    const selectedCurrency = e.target.value;
    this.updateAmount(selectedCurrency);
  }

  updateAmount(currency) {
    new CurrenciesService().get(currency).then((currency) => {
      this.amountTarget.step = currency.step;

      const rawValue = this.amountTarget.value.trim();
      if (rawValue !== "") {
        const parsedAmount = parseLocaleFloat(rawValue, { separator: currency.separator });
        if (Number.isFinite(parsedAmount)) {
          this.amountTarget.value = parsedAmount.toFixed(currency.default_precision);
        }
      }

      this.symbolTarget.innerText = currency.symbol;
    });
  }
}
