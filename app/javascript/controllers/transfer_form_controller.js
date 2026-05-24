import ExchangeRateFormController from "controllers/exchange_rate_form_controller";

// Connects to data-controller="transfer-form"
export default class extends ExchangeRateFormController {
  static targets = [
    ...ExchangeRateFormController.targets,
    "fromAccount",
    "toAccount"
  ];

  hasRequiredExchangeRateTargets() {
    if (!this.hasFromAccountTarget || !this.hasToAccountTarget || !this.hasDateTarget) {
      return false;
    }

    return true;
  }

  getExchangeRateContext() {
    if (!this.hasRequiredExchangeRateTargets()) {
      return null;
    }

    const fromAccountId = this.fromAccountTarget.value;
    const toAccountId = this.toAccountTarget.value;
    const date = this.dateTarget.value;

    if (!fromAccountId || !toAccountId) {
      return null;
    }

    const fromCurrency = this.accountCurrenciesValue[fromAccountId];
    const toCurrency = this.accountCurrenciesValue[toAccountId];

    if (!fromCurrency || !toCurrency) {
      return null;
    }

    return {
      fromCurrency,
      toCurrency,
      date
    };
  }

  isCurrentExchangeRateState(fromCurrency, toCurrency, date) {
    if (!this.hasRequiredExchangeRateTargets()) {
      return false;
    }

    const currentFromAccountId = this.fromAccountTarget.value;
    const currentToAccountId = this.toAccountTarget.value;
    const currentFromCurrency = this.accountCurrenciesValue[currentFromAccountId];
    const currentToCurrency = this.accountCurrenciesValue[currentToAccountId];
    const currentDate = this.dateTarget.value;

    return fromCurrency === currentFromCurrency && toCurrency === currentToCurrency && date === currentDate;
  }
}
