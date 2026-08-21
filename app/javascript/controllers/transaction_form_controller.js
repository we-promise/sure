import ExchangeRateFormController from "controllers/exchange_rate_form_controller";

// Connects to data-controller="transaction-form"
export default class extends ExchangeRateFormController {
  static targets = [
    ...ExchangeRateFormController.targets,
    "account",
    "currency"
  ];

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
