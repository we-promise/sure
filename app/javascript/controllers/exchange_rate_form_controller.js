import { Controller } from "@hotwired/stimulus";
import evaluateAmountExpression, {
  precisionFromStep,
} from "utils/evaluate_amount_expression";

export default class extends Controller {
  static targets = [
    "amount",
    "destinationAmount",
    "date",
    "exchangeRateContainer",
    "exchangeRateField",
    "convertDestinationDisplay",
    "calculateRateDisplay",
    "sourceCurrency",
    "destinationCurrency"
  ];

  static values = {
    exchangeRateUrl: String,
    accountCurrencies: Object
  };

  connect() {
    this.sourceCurrency = null;
    this.destinationCurrency = null;
    this.activeTab = "convert";

    // A money field reformats its text when its currency lookup lands, which
    // fires no "input", so the derived rate or destination is worked out again.
    this.recalculateAmounts = () => this.onAmountInputChange();
    this.element.addEventListener(
      "money-field:reformatted",
      this.recalculateAmounts,
    );

    if (!this.hasRequiredExchangeRateTargets()) {
      return;
    }

    this.checkCurrencyDifference();
  }

  disconnect() {
    this.element.removeEventListener(
      "money-field:reformatted",
      this.recalculateAmounts,
    );
  }

  hasRequiredExchangeRateTargets() {
    return this.hasDateTarget;
  }

  checkCurrencyDifference() {
    this.syncCurrencySources();

    const context = this.getExchangeRateContext();

    if (!context) {
      this.hideExchangeRateField();
      return;
    }

    const { fromCurrency, toCurrency, date } = context;

    if (!fromCurrency || !toCurrency) {
      this.hideExchangeRateField();
      return;
    }

    this.sourceCurrency = fromCurrency;
    this.destinationCurrency = toCurrency;

    if (fromCurrency === toCurrency) {
      this.hideExchangeRateField();
      return;
    }

    this.fetchExchangeRate(fromCurrency, toCurrency, date);
  }

  onExchangeRateTabClick(event) {
    const btn = event.target.closest("button[data-id]");
    if (!btn) {
      return;
    }

    const nextTab = btn.dataset.id;

    if (nextTab === this.activeTab) {
      return;
    }

    this.activeTab = nextTab;

    if (this.activeTab === "convert") {
      this.clearCalculateRateFields();
    } else if (this.activeTab === "calculateRate") {
      this.clearConvertFields();
    }
  }

  onAmountChange() {
    this.onAmountInputChange();
  }

  onSourceAmountChange() {
    this.onAmountInputChange();
  }

  onAmountInputChange() {
    if (!this.hasAmountTarget) {
      return;
    }

    if (this.activeTab === "convert") {
      this.calculateConvertDestination();
    } else {
      this.calculateRateFromAmounts();
    }
  }

  onConvertSourceAmountChange() {
    this.calculateConvertDestination();
  }

  onConvertExchangeRateChange() {
    this.calculateConvertDestination();
  }

  calculateConvertDestination() {
    if (!this.hasAmountTarget || !this.hasExchangeRateFieldTarget || !this.hasConvertDestinationDisplayTarget) {
      return;
    }

    // amountTarget is the shared money field, so it can hold a comma decimal
    // or expression ("12,50+4,30"); Number.parseFloat stops at the first
    // comma and silently truncates it. exchangeRateFieldTarget is a plain
    // type="number" input, which the browser already normalizes to a dot
    // decimal or empty string, so parseFloat is safe there.
    const amount = this.#submittedAmount(this.amountTarget);
    const rate = Number.parseFloat(this.exchangeRateFieldTarget.value);

    if (amount && rate && rate !== 0) {
      const destAmount = (amount * rate).toFixed(2);
      this.convertDestinationDisplayTarget.textContent = this.destinationCurrency ? `${destAmount} ${this.destinationCurrency}` : destAmount;
    } else {
      this.convertDestinationDisplayTarget.textContent = "-";
    }
  }

  onCalculateRateSourceAmountChange() {
    this.calculateRateFromAmounts();
  }

  onCalculateRateDestinationAmountChange() {
    this.calculateRateFromAmounts();
  }

  calculateRateFromAmounts() {
    if (!this.hasAmountTarget || !this.hasDestinationAmountTarget || !this.hasCalculateRateDisplayTarget || !this.hasExchangeRateFieldTarget) {
      return;
    }

    // Both amounts are money fields (see calculateConvertDestination above).
    const amount = this.#submittedAmount(this.amountTarget);
    const destAmount = this.#submittedAmount(this.destinationAmountTarget);

    if (amount && destAmount && amount !== 0) {
      const rate = destAmount / amount;
      const formattedRate = this.formatExchangeRate(rate);
      this.calculateRateDisplayTarget.textContent = formattedRate;
      this.exchangeRateFieldTarget.value = rate.toFixed(14);
    } else {
      this.calculateRateDisplayTarget.textContent = "-";
      this.exchangeRateFieldTarget.value = "";
    }
  }

  formatExchangeRate(rate) {
    let formattedRate = rate.toFixed(14);
    formattedRate = formattedRate.replace(/(\.\d{2}\d*?)0+$/, "$1");

    if (!formattedRate.includes(".")) {
      formattedRate += ".00";
    } else if (formattedRate.match(/\.\d$/)) {
      formattedRate += "0";
    }

    return formattedRate;
  }

  clearConvertFields() {
    if (this.hasExchangeRateFieldTarget) {
      this.exchangeRateFieldTarget.value = "";
    }
    if (this.hasConvertDestinationDisplayTarget) {
      this.convertDestinationDisplayTarget.textContent = "-";
    }
  }

  clearCalculateRateFields() {
    if (this.hasDestinationAmountTarget) {
      this.#clearDestinationAmount();
    }
    if (this.hasCalculateRateDisplayTarget) {
      this.calculateRateDisplayTarget.textContent = "-";
    }
    if (this.hasExchangeRateFieldTarget) {
      this.exchangeRateFieldTarget.value = "";
    }
  }

  async fetchExchangeRate(fromCurrency, toCurrency, date) {
    if (this.exchangeRateAbortController) {
      this.exchangeRateAbortController.abort();
    }

    this.exchangeRateAbortController = new AbortController();
    const signal = this.exchangeRateAbortController.signal;

    try {
      const url = new URL(this.exchangeRateUrlValue, window.location.origin);
      url.searchParams.set("from", fromCurrency);
      url.searchParams.set("to", toCurrency);
      if (date) {
        url.searchParams.set("date", date);
      }

      const response = await fetch(url, { signal });
      const data = await response.json();

      if (!this.isCurrentExchangeRateState(fromCurrency, toCurrency, date)) {
        return;
      }

      if (!response.ok) {
        if (this.shouldShowManualExchangeRate(data)) {
          this.showManualExchangeRateField();
        } else {
          this.hideExchangeRateField();
        }
        return;
      }

      if (data.same_currency) {
        this.hideExchangeRateField();
      } else {
        this.sourceCurrency = fromCurrency;
        this.destinationCurrency = toCurrency;
        this.showExchangeRateField(data.rate);
      }
    } catch (error) {
      if (error.name === "AbortError") {
        return;
      }

      console.error("Error fetching exchange rate:", error);
      this.hideExchangeRateField();
    }
  }

  showExchangeRateField(rate) {
    if (this.hasExchangeRateFieldTarget) {
      this.exchangeRateFieldTarget.value = this.formatExchangeRate(rate);
    }
    if (this.hasExchangeRateContainerTarget) {
      this.exchangeRateContainerTarget.classList.remove("hidden");
    }

    this.calculateConvertDestination();
  }

  showManualExchangeRateField() {
    const context = this.getExchangeRateContext();
    this.sourceCurrency = context?.fromCurrency || null;
    this.destinationCurrency = context?.toCurrency || null;

    if (this.hasExchangeRateFieldTarget) {
      this.exchangeRateFieldTarget.value = "";
    }
    if (this.hasExchangeRateContainerTarget) {
      this.exchangeRateContainerTarget.classList.remove("hidden");
    }

    this.calculateConvertDestination();
  }

  shouldShowManualExchangeRate(data) {
    if (!data || typeof data.error !== "string") {
      return false;
    }

    return data.error === "Exchange rate not found" || data.error === "Exchange rate unavailable";
  }

  hideExchangeRateField() {
    if (this.hasExchangeRateContainerTarget) {
      this.exchangeRateContainerTarget.classList.add("hidden");
    }
    if (this.hasExchangeRateFieldTarget) {
      this.exchangeRateFieldTarget.value = "";
    }
    if (this.hasConvertDestinationDisplayTarget) {
      this.convertDestinationDisplayTarget.textContent = "-";
    }
    if (this.hasCalculateRateDisplayTarget) {
      this.calculateRateDisplayTarget.textContent = "-";
    }
    if (this.hasDestinationAmountTarget) {
      this.#clearDestinationAmount();
    }

    this.sourceCurrency = null;
    this.destinationCurrency = null;
  }

  // The destination amount is a money field, which tracks its validity on
  // "input"; a stale invalid text would otherwise block submit while hidden.
  #clearDestinationAmount() {
    this.destinationAmountTarget.value = "";
    this.destinationAmountTarget.dispatchEvent(new Event("input", { bubbles: true }));
  }

  // Money fields whose currency follows an account picker read it from these
  // hidden inputs (money_field's currency_source), so a change is announced
  // with a "change" event. Subclasses return the currencies they know.
  syncCurrencySources() {
    const { source, destination } = this.currencySources();

    this.#setCurrencySource(this.hasSourceCurrencyTarget ? this.sourceCurrencyTarget : null, source);
    this.#setCurrencySource(this.hasDestinationCurrencyTarget ? this.destinationCurrencyTarget : null, destination);
  }

  currencySources() {
    return {};
  }

  #setCurrencySource(input, currency) {
    if (!input || !currency || input.value === currency) return;

    input.value = currency;
    input.dispatchEvent(new Event("change", { bubbles: true }));
  }

  getExchangeRateContext() {
    throw new Error("Subclasses must implement getExchangeRateContext()");
  }

  isCurrentExchangeRateState(_fromCurrency, _toCurrency, _date) {
    throw new Error("Subclasses must implement isCurrentExchangeRateState()");
  }

  // The amount as the money field submits it, read from the field's own
  // controller so the rate matches what the server saves, including while
  // the field's currency lookup is pending and before blur has rounded it.
  #submittedAmount(input) {
    const field = input.closest("[data-controller~='money-field']");
    const controller =
      field &&
      this.application.getControllerForElementAndIdentifier(field, "money-field");
    if (controller) return controller.submittedAmount();

    return evaluateAmountExpression(input.value, {
      precision: precisionFromStep(input.step),
    });
  }
}
