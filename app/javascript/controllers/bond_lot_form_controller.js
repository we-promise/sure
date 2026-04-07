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
    productTermMap: Object,
    productProviderMap: Object,
    lotAutoFetch: Boolean,
    globalImportEnabled: Boolean
  }

  connect() {
    this.syncSubtypeWithProduct()
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

    this.#syncTermWithProduct(productCode)
    this.#syncProviderWithProduct(productCode)

    this.#toggleSubtypeFields()
  }

  toggleSubtypeFields() {
    this.#toggleSubtypeFields()
  }

  toggleManualInflationField() {
    this.#toggleManualInflationField()
  }

  syncAutoFetchWithProvider() {
    if (!this.globalImportEnabledValue) return

    const autoFetchInput = this.element.querySelector('[data-bond-lot-form-target="autoFetchInput"]')
    const providerSelect = this.element.querySelector('[data-bond-lot-form-target="providerSelect"]')
    if (!autoFetchInput || !providerSelect) return

    const provider = `${providerSelect.value || ""}`.trim()
    autoFetchInput.value = provider === "" ? "0" : "1"
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

  #syncTermWithProduct(productCode) {
    const termInput = this.element.querySelector('input[name="bond_lot[term_months]"]')
    if (!termInput) return

    const mappedTerm = this.productTermMapValue?.[productCode]
    const termDerived = mappedTerm !== undefined && mappedTerm !== null && `${mappedTerm}` !== ""

    if (termDerived) {
      termInput.value = mappedTerm
    }

    termInput.readOnly = termDerived
  }

  #syncProviderWithProduct(productCode) {
    const providerSelect = this.element.querySelector('select[name="bond_lot[inflation_provider]"]')
    if (!providerSelect) return

    const mappedProvider = this.productProviderMapValue?.[productCode]
    const providerDerived = mappedProvider !== undefined && mappedProvider !== null && `${mappedProvider}` !== ""

    if (providerDerived) {
      providerSelect.value = mappedProvider
    } else if (productCode) {
      providerSelect.value = ""
    }

    providerSelect.disabled = providerDerived
    this.syncAutoFetchWithProvider()
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
