import ExchangeRateFormController from "controllers/exchange_rate_form_controller";

// Connects to data-controller="transaction-form"
export default class extends ExchangeRateFormController {
  static targets = [
    ...ExchangeRateFormController.targets,
    "account",
    "currency",
    "idempotencyKey"
  ];

  connect() {
    super.connect();

    // Turbo (and the browser bfcache) can restore this exact page - and its
    // hidden idempotency field - without a server round trip: back button,
    // a duplicated tab, or a snapshot cache hit. If the original submission
    // already committed, replaying that token on a *different* edited
    // submission would silently redirect onto the stale entry instead of
    // creating the new one. Rotate it right before Turbo snapshots the page
    // so any later restore starts from a fresh, unconsumed token.
    this.refreshIdempotencyKey = this.refreshIdempotencyKey.bind(this);
    document.addEventListener("turbo:before-cache", this.refreshIdempotencyKey);
  }

  disconnect() {
    document.removeEventListener("turbo:before-cache", this.refreshIdempotencyKey);
    super.disconnect();
  }

  refreshIdempotencyKey() {
    if (this.hasIdempotencyKeyTarget) {
      this.idempotencyKeyTarget.value = crypto.randomUUID();
    }
  }

  hasRequiredExchangeRateTargets() {
    if (!this.hasAccountTarget || !this.hasCurrencyTarget || !this.hasDateTarget) {
      return false;
    }

    return true;
  }

  getExchangeRateContext() {
    if (!this.hasRequiredExchangeRateTargets()) {
      return null;
    }

    const accountId = this.accountTarget.value;
    const currency = this.currencyTarget.value;
    const date = this.dateTarget.value;

    if (!accountId || !currency) {
      return null;
    }

    const accountCurrency = this.accountCurrenciesValue[accountId];
    if (!accountCurrency) {
      return null;
    }

    return {
      fromCurrency: currency,
      toCurrency: accountCurrency,
      date
    };
  }

  isCurrentExchangeRateState(fromCurrency, toCurrency, date) {
    if (!this.hasRequiredExchangeRateTargets()) {
      return false;
    }

    const currentAccountId = this.accountTarget.value;
    const currentCurrency = this.currencyTarget.value;
    const currentDate = this.dateTarget.value;
    const currentAccountCurrency = this.accountCurrenciesValue[currentAccountId];

    return fromCurrency === currentCurrency && toCurrency === currentAccountCurrency && date === currentDate;
  }

  onCurrencyChange() {
    this.checkCurrencyDifference();
  }
}
