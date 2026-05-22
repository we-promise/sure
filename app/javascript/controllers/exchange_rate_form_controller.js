import { Controller } from "@hotwired/stimulus";

export default class extends Controller {
  static targets = [
    "amount",
    "destinationAmount",
    "date",
    "exchangeRateContainer",
    "exchangeRateField",
    "convertDestinationDisplay",
    "calculateRateDisplay"
  ];

  static values = {
    exchangeRateUrl: String,
    accountCurrencies: Object
  };

  connect() {
    this.sourceCurrency = null;
    this.destinationCurrency = null;
    this.activeTab = "convert";

    if (!this.hasRequiredExchangeRateTargets()) {
      return;
    }

    this.checkCurrencyDifference();
  }

  hasRequiredExchangeRateTargets() {
    return this.hasDateTarget;
  }

  checkCurrencyDifference() {
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

    const amount = Number.parseFloat(this.amountTarget.value);
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

    const amount = Number.parseFloat(this.amountTarget.value);
    const destAmount = Number.parseFloat(this.destinationAmountTarget.value);

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
      this.destinationAmountTarget.value = "";
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
      this.destinationAmountTarget.value = "";
    }

    this.sourceCurrency = null;
    this.destinationCurrency = null;
  }

  getExchangeRateContext() {
    throw new Error("Subclasses must implement getExchangeRateContext()");
  }

  isCurrentExchangeRateState(_fromCurrency, _toCurrency, _date) {
    throw new Error("Subclasses must implement isCurrentExchangeRateState()");
  }
}
