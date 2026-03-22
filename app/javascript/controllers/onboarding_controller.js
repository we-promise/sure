import { Controller } from "@hotwired/stimulus";

// Connects to data-controller="onboarding"
export default class extends Controller {
  static targets = ["nameField", "monikerRadio"]
  static values = {
    householdNameLabel: String,
    householdNamePlaceholder: String,
    groupNameLabel: String,
    groupNamePlaceholder: String
  }

  connect() {
    this.updateNameFieldForCurrentMoniker();
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
