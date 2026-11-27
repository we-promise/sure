import { Controller } from "@hotwired/stimulus";

// Keeps a hidden currency input in step with an account picker, so a money
// field that follows that input (money_field's currency_source) shows and
// reads the picked account's currency. The picker names its input with
// data-currency-input (a CSS selector); accounts not in the map, such as a
// new account, fall back to the default currency.
export default class extends Controller {
  static values = { currencies: Object, fallback: String };

  // A picker the browser restored (back navigation) fires no "change".
  connect() {
    for (const picker of this.element.querySelectorAll("[data-currency-input]")) {
      this.#sync(picker);
    }
  }

  follow(event) {
    this.#sync(event.target);
  }

  #sync(picker) {
    const input = this.element.querySelector(picker.dataset.currencyInput);
    if (!input) return;

    const currency = this.currenciesValue[picker.value] || this.fallbackValue;
    if (!currency || input.value === currency) return;

    input.value = currency;
    input.dispatchEvent(new Event("change", { bubbles: true }));
  }
}
