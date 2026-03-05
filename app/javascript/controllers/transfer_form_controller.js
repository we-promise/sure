import { Controller } from "@hotwired/stimulus";

// Connects to data-controller="transfer-form"
export default class extends Controller {
  static targets = ["fromAccount", "toAccount", "amount", "destinationAmount", "date", "exchangeRateContainer", "exchangeRateField", "convertTab", "calculateRateTab", "convertContent", "calculateRateContent", "convertDestinationDisplay", "calculateRateDisplay"];
  static values = {
    exchangeRateUrl: String
  };

  connect() {
    this.checkCurrencyDifference();
    this.fromCurrency = null;
    this.toCurrency = null;
    this.activeTab = "convert"; // Start with convert tab
  }

  // Called when from/to account or date changes
  checkCurrencyDifference() {
    const fromAccountId = this.fromAccountTarget.value;
    const toAccountId = this.toAccountTarget.value;
    const date = this.dateTarget.value;

    if (!fromAccountId || !toAccountId) {
      this.hideExchangeRateField();
      return;
    }

    this.fetchExchangeRate(fromAccountId, toAccountId, date);
  }

  // Switch to convert tab (source amount + exchange rate)
  switchToConvertTab() {
    this.activeTab = "convert";
    this.updateTabUI();
    this.clearCalculateRateFields();
  }

  // Switch to calculate rate tab (source + destination amount)
  switchToCalculateRateTab() {
    this.activeTab = "calculateRate";
    this.updateTabUI();
    this.clearConvertFields();
  }

  updateTabUI() {
    if (this.activeTab === "convert") {
      this.convertTabTarget.classList.add("border-primary", "text-primary");
      this.convertTabTarget.classList.remove("border-transparent", "text-secondary", "opacity-60");
      this.calculateRateTabTarget.classList.remove("border-primary", "text-primary");
      this.calculateRateTabTarget.classList.add("border-transparent", "text-secondary", "opacity-60");
      this.convertContentTarget.classList.remove("hidden");
      this.calculateRateContentTarget.classList.add("hidden");
    } else {
      this.convertTabTarget.classList.remove("border-primary", "text-primary");
      this.convertTabTarget.classList.add("border-transparent", "text-secondary", "opacity-60");
      this.calculateRateTabTarget.classList.add("border-primary", "text-primary");
      this.calculateRateTabTarget.classList.remove("border-transparent", "text-secondary", "opacity-60");
      this.convertContentTarget.classList.add("hidden");
      this.calculateRateContentTarget.classList.remove("hidden");
    }
  }

  // Called when source amount changes - dispatches to correct handler
  onSourceAmountChange() {
    if (this.activeTab === "convert") {
      this.calculateConvertDestination();
    } else {
      this.calculateRateFromAmounts();
    }
  }

  // Called when source amount changes in convert tab
  onConvertSourceAmountChange() {
    this.calculateConvertDestination();
  }

  // Called when exchange rate changes in convert tab
  onConvertExchangeRateChange() {
    this.calculateConvertDestination();
  }

  // Calculate destination amount from source + exchange rate
  calculateConvertDestination() {
    const sourceAmount = Number.parseFloat(this.amountTarget.value);
    const rate = Number.parseFloat(this.exchangeRateFieldTarget.value);

    if (sourceAmount && rate && rate !== 0) {
      const destAmount = (sourceAmount * rate).toFixed(2);
      this.convertDestinationDisplayTarget.textContent = `${destAmount} ${this.toCurrency}`;
    } else {
      this.convertDestinationDisplayTarget.textContent = "-";
    }
  }

  // Called when source amount changes in calculate rate tab
  onCalculateRateSourceAmountChange() {
    this.calculateRateFromAmounts();
  }

  // Called when destination amount changes in calculate rate tab
  onCalculateRateDestinationAmountChange() {
    this.calculateRateFromAmounts();
  }

  // Calculate exchange rate from source + destination amounts
  calculateRateFromAmounts() {
    const sourceAmount = Number.parseFloat(this.amountTarget.value);
    const destAmount = Number.parseFloat(this.destinationAmountTarget.value);

    if (sourceAmount && destAmount && sourceAmount !== 0) {
      const rate = destAmount / sourceAmount;
      const formattedRate = this.formatExchangeRate(rate);
      this.calculateRateDisplayTarget.textContent = formattedRate;
      // Also update the hidden exchange_rate field so it gets submitted
      this.exchangeRateFieldTarget.value = rate.toFixed(14);
    } else {
      this.calculateRateDisplayTarget.textContent = "-";
      this.exchangeRateFieldTarget.value = "";
    }
  }

  // Format exchange rate: show 2 decimals minimum, up to 14 if needed
  // Note: toFixed() always uses period (.) as decimal separator regardless of locale (per ECMAScript spec)
  formatExchangeRate(rate) {
    // Convert to string with 14 decimals
    let formattedRate = rate.toFixed(14);
    // Remove trailing zeros, but keep at least 2 decimal places
    formattedRate = formattedRate.replace(/(\.\d{2}\d*?)0+$/, '$1');
    // If we removed all decimals after the required 2, ensure we have exactly 2
    if (!formattedRate.includes('.')) {
      formattedRate += '.00';
    } else if (formattedRate.match(/\.\d$/)) {
      formattedRate += '0';
    }
    return formattedRate;
  }

  clearConvertFields() {
    this.exchangeRateFieldTarget.value = "";
    this.convertDestinationDisplayTarget.textContent = "-";
  }

  clearCalculateRateFields() {
    this.destinationAmountTarget.value = "";
    this.calculateRateDisplayTarget.textContent = "-";
    this.exchangeRateFieldTarget.value = "";
  }

  async fetchExchangeRate(fromAccountId, toAccountId, date) {
    // Cancel any previous in-flight request
    if (this.exchangeRateAbortController) {
      this.exchangeRateAbortController.abort();
    }

    // Create new AbortController for this request
    this.exchangeRateAbortController = new AbortController();
    const signal = this.exchangeRateAbortController.signal;

    try {
      const url = new URL(this.exchangeRateUrlValue, window.location.origin);
      url.searchParams.set("from_account_id", fromAccountId);
      url.searchParams.set("to_account_id", toAccountId);
      if (date) {
        url.searchParams.set("date", date);
      }

      const response = await fetch(url, { signal });
      if (!response.ok) {
        this.hideExchangeRateField();
        return;
      }

      const data = await response.json();

      // Validate response matches current form state to guard against out-of-order completions
      const currentFromAccountId = this.fromAccountTarget.value;
      const currentToAccountId = this.toAccountTarget.value;
      const currentDate = this.dateTarget.value;

      if (fromAccountId !== currentFromAccountId || toAccountId !== currentToAccountId || date !== currentDate) {
        // Response is stale, ignore it
        return;
      }

      if (data.same_currency) {
        this.hideExchangeRateField();
      } else {
        this.fromCurrency = data.from_currency;
        this.toCurrency = data.to_currency;
        this.showExchangeRateField(data.rate);
      }
    } catch (error) {
      // Don't log AbortError as it's expected when canceling requests
      if (error.name === "AbortError") {
        return;
      }
      console.error("Error fetching exchange rate:", error);
      this.hideExchangeRateField();
    }
  }

  showExchangeRateField(rate) {
    this.exchangeRateFieldTarget.value = this.formatExchangeRate(rate);
    this.exchangeRateContainerTarget.classList.remove("hidden");
    // Pre-calculate destination display
    this.calculateConvertDestination();
  }

  hideExchangeRateField() {
    this.exchangeRateContainerTarget.classList.add("hidden");
    this.exchangeRateFieldTarget.value = "";
    this.convertDestinationDisplayTarget.textContent = "-";
    this.calculateRateDisplayTarget.textContent = "-";
    this.destinationAmountTarget.value = "";
    this.fromCurrency = null;
    this.toCurrency = null;
  }
}
