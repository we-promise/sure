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
      this.idempotencyKeyTarget.value = this.#generateUUID();
    }
  }

  refreshIdempotencyKeyIfPersisted(event) {
    if (event.persisted) {
      this.refreshIdempotencyKey();
    }
  }

  // crypto.randomUUID() only exists in secure contexts (HTTPS/localhost),
  // but self-hosted deployments of this app are commonly reverse-proxied or
  // reached over plain HTTP on a LAN, where it's undefined and would throw
  // from inside the cache-restore handlers above - leaving the stale,
  // already-consumed token in place. crypto.getRandomValues has no such
  // restriction, so build a v4 UUID manually when randomUUID is missing;
  // the server's UUID_FORMAT check requires this exact shape.
  #generateUUID() {
    if (crypto.randomUUID) {
      return crypto.randomUUID();
    }

    const bytes = crypto.getRandomValues(new Uint8Array(16));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    const hex = [ ...bytes ].map((byte) => byte.toString(16).padStart(2, "0"));

    return [
      hex.slice(0, 4).join(""),
      hex.slice(4, 6).join(""),
      hex.slice(6, 8).join(""),
      hex.slice(8, 10).join(""),
      hex.slice(10, 16).join("")
    ].join("-");
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
