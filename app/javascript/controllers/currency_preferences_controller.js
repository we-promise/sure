import { Controller } from "@hotwired/stimulus";

export default class extends Controller {
  static targets = ["dialog", "checkbox", "selectedCount"];
  static values = {
    baseCurrency: String,
    locale: String,
    selectedCountTranslations: Object,
  };

  connect() {
    this.updateSelectedCount();
  }

  open() {
    this.updateSelectedCount();
    this.dialogTarget.showModal();
  }

  selectAll() {
    this.checkboxTargets.forEach((checkbox) => {
      checkbox.checked = true;
    });

    this.updateSelectedCount();
  }

  selectBaseOnly() {
    this.checkboxTargets.forEach((checkbox) => {
      checkbox.checked = checkbox.value === this.baseCurrencyValue;
    });

    this.updateSelectedCount();
  }

  updateSelectedCount() {
    if (!this.hasSelectedCountTarget) return;

    const selectedCount = this.checkboxTargets.filter((checkbox) => checkbox.checked).length;
    const pluralRules = new Intl.PluralRules(this.localeValue || undefined);
    const pluralCategory = pluralRules.select(selectedCount);
    const labelTemplate =
      this.selectedCountTranslationsValue[pluralCategory] ||
      this.selectedCountTranslationsValue.other ||
      "%{count}";
    const label = labelTemplate.replace("%{count}", selectedCount);

    this.selectedCountTarget.textContent = label;
  }

  handleSubmitEnd(event) {
    if (!event.detail.success) return;
    if (!this.dialogTarget.open) return;

    this.dialogTarget.close();
  }
}
