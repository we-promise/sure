import ExchangeRateFormController from "controllers/exchange_rate_form_controller";

// Connects to data-controller="transaction-form"
export default class extends ExchangeRateFormController {
  static targets = [
    ...ExchangeRateFormController.targets,
    "account",
    "currency",
    "idempotencyKey"
  ];

  // Two independent restoration paths can hand a user this exact page - and
  // its hidden idempotency field - back without a server round trip: Turbo's
  // own snapshot cache (back button within the app, wired via
  // turbo:before-cache) and the browser's native bfcache (back/forward
  // across a full navigation, or a duplicated tab, wired via a persisted
  // pageshow). Either one skips the "new" action's SecureRandom.uuid, so if
  // the original submission already committed, replaying that token on a
  // *different*, edited submission would silently redirect onto the stale
  // entry instead of creating the new one. Rotating on both events - rather
  // than only one - ensures any later restore starts from a fresh,
  // unconsumed token regardless of which cache served the page.
  refreshIdempotencyKey() {
    if (this.hasIdempotencyKeyTarget) {
      this.idempotencyKeyTarget.value = crypto.randomUUID();
    }
  }

  refreshIdempotencyKeyIfPersisted(event) {
    if (event.persisted) {
      this.refreshIdempotencyKey();
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
