import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = [
    "productCodeSelect",
    "subtypeSelect",
    "subtypeDerivedHint",
    "inflationFields",
    "otherFields",
    "inflationInput",
    "otherRequiredInput",
    "providerSelect",
    "autoFetchInput",
    "manualInflationField",
    "manualInflationInput"
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

  syncIssueDateWithPurchase() {
    const purchasedOnInput = this.element.querySelector('input[name="bond_lot[purchased_on]"]')
    const issueDateInput = this.element.querySelector('input[name="bond_lot[issue_date]"]')
    if (!purchasedOnInput || !issueDateInput) return

    if (!issueDateInput.value && purchasedOnInput.value) {
      issueDateInput.value = purchasedOnInput.value
    }
  }

  syncAutoFetchWithProvider() {
    if (!this.globalImportEnabledValue) return

    if (!this.hasAutoFetchInputTarget || !this.hasProviderSelectTarget) return

    const provider = `${this.providerSelectTarget.value || ""}`.trim()
    this.autoFetchInputTarget.value = provider === "" ? "0" : "1"
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
    if (!this.hasManualInflationFieldTarget || !this.hasManualInflationInputTarget) return

    const inflationLinked = this.inflationSubtypesValue.includes(this.subtypeSelectTarget.value)
    const autoFetch = this.#currentAutoFetchValue()
    const showManualField = inflationLinked && (!autoFetch || !this.globalImportEnabledValue)
    const required = inflationLinked && !autoFetch

    this.manualInflationFieldTarget.classList.toggle("hidden", !showManualField)
    this.manualInflationInputTarget.disabled = !showManualField
    this.manualInflationInputTarget.required = required
  }

  #currentAutoFetchValue() {

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
