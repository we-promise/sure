import { Controller } from "@hotwired/stimulus";
import submittedAmount from "utils/submitted_amount";

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
    // A form redrawn after a rejected submit carries the rate that was
    // entered; the first lookup must not replace it with the market rate.
    this.currencyCheckStarted = false;
    this.keepRenderedRate =
      this.hasExchangeRateFieldTarget &&
      this.exchangeRateFieldTarget.value.trim() !== "";

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
    // Only the lookup started on connect may keep a redrawn rate: once the
    // accounts or date change, the rate belongs to another pair or day.
    if (this.currencyCheckStarted) this.keepRenderedRate = false;
    this.currencyCheckStarted = true;
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

    // Both are money fields, so they can hold a comma decimal or an
    // expression ("12,50+4,30", "1/0,92"); Number.parseFloat would stop at
    // the first comma and silently truncate it.
    const amount = submittedAmount(this.application, this.amountTarget);
    const rate = submittedAmount(this.application, this.exchangeRateFieldTarget);

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
    const amount = submittedAmount(this.application, this.amountTarget);
    const destAmount = submittedAmount(this.application, this.destinationAmountTarget);

    if (amount && destAmount && amount !== 0) {
      const rate = destAmount / amount;
      const formattedRate = this.formatExchangeRate(rate);
      this.calculateRateDisplayTarget.textContent = formattedRate;
      this.#setExchangeRate(rate.toFixed(14));
    } else {
      this.calculateRateDisplayTarget.textContent = "-";
      this.#setExchangeRate("");
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
      this.#setExchangeRate("");
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
      this.#setExchangeRate("");
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
    if (this.hasExchangeRateFieldTarget && !this.#takeRenderedRate()) {
      // On the calculate tab the rate follows the typed destination amount,
      // not the market rate.
      if (this.activeTab === "calculateRate") {
        this.calculateRateFromAmounts();
      } else {
        this.#setExchangeRate(this.formatExchangeRate(rate));
      }
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

    if (this.hasExchangeRateFieldTarget && !this.#takeRenderedRate()) {
      this.#setExchangeRate("");
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
    this.keepRenderedRate = false;
    if (this.hasExchangeRateContainerTarget) {
      this.exchangeRateContainerTarget.classList.add("hidden");
    }
    if (this.hasExchangeRateFieldTarget) {
      this.#setExchangeRate("");
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

  // True once, for the first lookup after connect when the form was drawn
  // with a rate; any later lookup (another account or date) replaces it.
  #takeRenderedRate() {
    const keep = this.keepRenderedRate;
    this.keepRenderedRate = false;
    return keep;
  }

  // The rate is a money field, which tracks its validity on "input", so a
  // rate written here clears a stale invalid text the user left in it.
  #setExchangeRate(value) {
    this.exchangeRateFieldTarget.value = value;
    this.exchangeRateFieldTarget.dispatchEvent(new Event("input", { bubbles: true }));
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
}
