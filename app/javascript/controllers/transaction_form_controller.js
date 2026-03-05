import { Controller } from "@hotwired/stimulus";

// Connects to data-controller="transaction-form"
export default class extends Controller {
  static targets = [
    "account",
    "currency",
    "amount",
    "destinationAmount",
    "date",
    "exchangeRateContainer",
    "exchangeRateField",
    "convertTab",
    "calculateRateTab",
    "convertContent",
    "calculateRateContent",
    "convertDestinationDisplay",
    "calculateRateDisplay"
  ];
  static values = {
    exchangeRateUrl: String
  };

  connect() {
    this.checkCurrencyDifference();
    this.accountCurrency = null;
    this.transactionCurrency = null;
    this.activeTab = "convert"; // Start with convert tab
  }

  // Called when account, currency, or date changes
  checkCurrencyDifference() {
    const accountId = this.accountTarget.value;
    const currency = this.currencyTarget.value;
    const date = this.dateTarget.value;

    if (!accountId || !currency) {
      this.hideExchangeRateField();
      return;
    }

    this.fetchExchangeRate(accountId, currency, date);
  }

  // Called when currency changes (triggered from money_field controller)
  onCurrencyChange() {
    this.checkCurrencyDifference();
  }

  // Switch to convert tab (amount + exchange rate)
  switchToConvertTab() {
    this.activeTab = "convert";
    this.updateTabUI();
    this.clearCalculateRateFields();
  }

  // Switch to calculate rate tab (amount + destination amount)
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

  // Called when amount changes - dispatches to correct handler
  onAmountChange() {
    if (this.activeTab === "convert") {
      this.calculateConvertDestination();
    } else {
      this.calculateRateFromAmounts();
    }
  }

  // Called when amount changes in convert tab
  onConvertAmountChange() {
    this.calculateConvertDestination();
  }

  // Called when exchange rate changes in convert tab
  onConvertExchangeRateChange() {
    this.calculateConvertDestination();
  }

  // Calculate destination amount from source + exchange rate
  calculateConvertDestination() {
    const amount = Number.parseFloat(this.amountTarget.value);
    const rate = Number.parseFloat(this.exchangeRateFieldTarget.value);

    if (amount && rate && rate !== 0) {
      const destAmount = (amount * rate).toFixed(2);
      this.convertDestinationDisplayTarget.textContent = `${destAmount} ${this.accountCurrency}`;
    } else {
      this.convertDestinationDisplayTarget.textContent = "-";
    }
  }

  // Called when amount changes in calculate rate tab
  onCalculateRateAmountChange() {
    this.calculateRateFromAmounts();
  }

  // Called when destination amount changes in calculate rate tab
  onCalculateRateDestinationAmountChange() {
    this.calculateRateFromAmounts();
  }

  // Calculate exchange rate from source + destination amounts
  calculateRateFromAmounts() {
    const amount = Number.parseFloat(this.amountTarget.value);
    const destAmount = Number.parseFloat(this.destinationAmountTarget.value);

    if (amount && destAmount && amount !== 0) {
      const rate = destAmount / amount;
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

  async fetchExchangeRate(accountId, currency, date) {
    // Cancel any previous in-flight request
    if (this.exchangeRateAbortController) {
      this.exchangeRateAbortController.abort();
    }

    // Create new AbortController for this request
    this.exchangeRateAbortController = new AbortController();
    const signal = this.exchangeRateAbortController.signal;

    try {
      const url = new URL(this.exchangeRateUrlValue, window.location.origin);
      url.searchParams.set("account_id", accountId);
      url.searchParams.set("currency", currency);
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
      const currentAccountId = this.accountTarget.value;
      const currentCurrency = this.currencyTarget.value;
      const currentDate = this.dateTarget.value;

      if (accountId !== currentAccountId || currency !== currentCurrency || date !== currentDate) {
        // Response is stale, ignore it
        return;
      }

      if (data.same_currency) {
        this.hideExchangeRateField();
      } else {
        this.transactionCurrency = currency;
        this.accountCurrency = data.account_currency;
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
    this.transactionCurrency = null;
    this.accountCurrency = null;
  }
}
