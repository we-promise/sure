import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = [
    "productCodeSelect",
    "subtypeSelect",
    "subtypeDerivedHint",
    "inflationFields",
    "otherFields",
    "inflationInput",
    "otherRequiredInput"
  ]
  static values = {
    inflationSubtypes: Array,
    productSubtypeMap: Object,
    lotAutoFetch: Boolean,
    globalImportEnabled: Boolean
  }

  connect() {
    this.syncSubtypeWithProduct()
    this.#toggleSubtypeFields()
  }

  syncSubtypeWithProduct() {
    if (!this.hasProductCodeSelectTarget || !this.hasSubtypeSelectTarget) return

    const productCode = this.productCodeSelectTarget.value
    const mappedSubtype = this.productSubtypeMapValue?.[productCode]
    const subtypeDerived = Boolean(mappedSubtype)

    if (subtypeDerived) {
      this.subtypeSelectTarget.value = mappedSubtype
    }

    this.subtypeSelectTarget.disabled = subtypeDerived

    if (this.hasSubtypeDerivedHintTarget) {
      this.subtypeDerivedHintTarget.classList.toggle("hidden", !subtypeDerived)
    }

    this.#toggleSubtypeFields()
  }

  toggleSubtypeFields() {
    this.#toggleSubtypeFields()
  }

  toggleManualInflationField() {
    this.#toggleManualInflationField()
  }

  #toggleSubtypeFields() {
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
      input.required = inflationLinked && !input.dataset.optional
    })

    this.otherRequiredInputTargets.forEach((input) => {
      input.disabled = inflationLinked
      input.required = !inflationLinked
    })

    this.#toggleManualInflationField()
  }

  #toggleManualInflationField() {
    const manualInflationField = this.element.querySelector('[data-bond-lot-form-target="manualInflationField"]')
    const manualInflationInput = this.element.querySelector('[data-bond-lot-form-target="manualInflationInput"]')
    if (!manualInflationField || !manualInflationInput) return

    const inflationLinked = this.inflationSubtypesValue.includes(this.subtypeSelectTarget.value)
    const autoFetch = this.#currentAutoFetchValue()
    const showManualField = inflationLinked && (!autoFetch || !this.globalImportEnabledValue)
    const required = inflationLinked && !autoFetch

    manualInflationField.classList.toggle("hidden", !showManualField)
    manualInflationInput.disabled = !showManualField
    manualInflationInput.required = required
  }

  #currentAutoFetchValue() {
    const autoFetchInput = this.element.querySelector('[data-bond-lot-form-target="autoFetchInput"]')

    if (autoFetchInput) {
      if (autoFetchInput.type === "checkbox") {
        return autoFetchInput.checked
      }

      const value = `${autoFetchInput.value}`.trim().toLowerCase()
      return value === "1" || value === "true"
    }

    return this.lotAutoFetchValue
  }
}
