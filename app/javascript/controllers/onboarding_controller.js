import { Controller } from "@hotwired/stimulus";

// Connects to data-controller="onboarding"
export default class extends Controller {
  static targets = ["nameField", "monikerRadio", "countryField", "currencyField"]
  static values = {
    householdNameLabel: String,
    householdNamePlaceholder: String,
    groupNameLabel: String,
    groupNamePlaceholder: String,
    country: String,
    countryCurrencies: Object,
    currencyOverride: Boolean
  }

  connect() {
    this.updateNameFieldForCurrentMoniker();
    this.applyBrowserLocaleDefaults();
  }

  setLocale(event) {
    this.refreshWithParam("locale", event.target.value);
  }

  setDateFormat(event) {
    this.refreshWithParam("date_format", event.target.value);
  }

  setCurrency(event) {
    this.refreshWithParam("currency", event.target.value);
  }

  setTheme(event) {
    document.documentElement.setAttribute("data-theme", event.target.value);
  }

  applyBrowserLocaleDefaults() {
    const browserCountry = this.browserCountry();

    if (this.hasCountryFieldTarget && browserCountry && this.countryFieldTarget.value === "US" && this.hasCountryOption(browserCountry)) {
      this.countryFieldTarget.value = browserCountry;
    }

    if (this.hasCurrencyFieldTarget && !this.currencyOverrideValue) {
      const country = this.countryValue || (this.hasCountryFieldTarget ? this.countryFieldTarget.value : null) || browserCountry;
      const currency = this.currencyForCountry(country);

      if (currency && this.hasCurrencyOption(currency)) {
        this.currencyFieldTarget.value = currency;
      }
    }
  }

  browserCountry() {
    try {
      return new Intl.Locale(navigator.language).maximize().region;
    } catch (_error) {
      return null;
    }
  }

  currencyForCountry(country) {
    return (this.hasCountryCurrenciesValue ? this.countryCurrenciesValue : {})[country?.toUpperCase()];
  }

  hasCountryOption(country) {
    return Array.from(this.countryFieldTarget.options).some((option) => option.value === country);
  }

  hasCurrencyOption(currency) {
    return Array.from(this.currencyFieldTarget.options).some((option) => option.value === currency);
  }

  updateNameFieldForCurrentMoniker(event = null) {
    if (!this.hasNameFieldTarget) {
      return;
    }

    const selectedMonikerRadio = event?.target?.dataset?.onboardingMoniker ? event.target : this.monikerRadioTargets.find((radio) => radio.checked);
    const selectedMoniker = selectedMonikerRadio?.dataset?.onboardingMoniker;
    const isGroup = selectedMoniker === "Group";

    this.nameFieldTarget.placeholder = isGroup ? this.groupNamePlaceholderValue : this.householdNamePlaceholderValue;

    const label = this.nameFieldTarget.closest(".form-field")?.querySelector(".form-field__label");
    if (!label) {
      return;
    }

    if (isGroup) {
      label.textContent = this.groupNameLabelValue;
      return;
    }

    label.textContent = this.householdNameLabelValue;
  }

  refreshWithParam(key, value) {
    const url = new URL(window.location);
    url.searchParams.set(key, value);

    // Preserve existing params by getting the current search string
    // and appending our new param to it
    const currentParams = new URLSearchParams(window.location.search);
    currentParams.set(key, value);

    // Refresh the page with all params
    window.location.search = currentParams.toString();
  }
}
