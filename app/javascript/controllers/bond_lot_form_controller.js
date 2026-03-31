import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = [
    "subtypeSelect",
    "inflationFields",
    "otherFields",
    "inflationInput",
    "otherRequiredInput",
    "manualInflationField",
    "manualInflationInput"
  ]
  static values = {
    inflationSubtypes: Array,
    globalAutoFetchEnabled: Boolean
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
    const autoFetch = this.globalAutoFetchEnabledValue
    const showManualField = inflationLinked && !autoFetch

    this.manualInflationFieldTarget.classList.toggle("hidden", !showManualField)
    this.manualInflationInputTarget.disabled = !showManualField
    this.manualInflationInputTarget.required = showManualField
  }
}
