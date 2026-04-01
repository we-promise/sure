import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = [
    "subtypeSelect",
    "inflationFields",
    "otherFields",
    "inflationInput",
    "otherRequiredInput",
    "manualInflationField",
    "manualInflationInput",
    "autoFetchInput"
  ]
  static values = {
    inflationSubtypes: Array,
    lotAutoFetch: Boolean,
    globalImportEnabled: Boolean
  }

  connect() {
    this.toggleSubtypeFields()
  }

  toggleSubtypeFields() {
    const subtype = this.subtypeSelectTarget.value
    const inflationLinked = this.inflationSubtypesValue.includes(subtype)

    this.inflationFieldsTargets.forEach((element) => {
      element.classList.toggle("hidden", !inflationLinked)
    })

    this.otherFieldsTargets.forEach((element) => {
      element.classList.toggle("hidden", inflationLinked)
    })

    this.inflationInputTargets.forEach((input) => {
      input.disabled = !inflationLinked
      input.required = inflationLinked && input.name !== "bond_lot[early_redemption_fee]"
    })

    this.otherRequiredInputTargets.forEach((input) => {
      input.disabled = inflationLinked
      input.required = !inflationLinked
    })

    this.toggleManualInflationField()
  }

  toggleManualInflationField() {
    if (!this.hasManualInflationFieldTarget || !this.hasManualInflationInputTarget) return

    const inflationLinked = this.inflationSubtypesValue.includes(this.subtypeSelectTarget.value)
    const autoFetch = this.currentAutoFetchValue()
    const showManualField = inflationLinked && (!autoFetch || this.globalImportEnabledValue)
    const required = inflationLinked && !autoFetch

    this.manualInflationFieldTarget.classList.toggle("hidden", !showManualField)
    this.manualInflationInputTarget.disabled = !showManualField
    this.manualInflationInputTarget.required = required
  }

  currentAutoFetchValue() {
    if (this.hasAutoFetchInputTarget) {
      if (this.autoFetchInputTarget.type === "checkbox") {
        return this.autoFetchInputTarget.checked
      }

      const value = `${this.autoFetchInputTarget.value}`.trim().toLowerCase()
      return value === "1" || value === "true"
    }

    return this.lotAutoFetchValue
  }
}
