import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["productCodeSelect", "subtypeSelect", "subtypeDerivedHint", "providerSelect"]
  static values = {
    productSubtypeMap: Object,
    productTermMap: Object,
    productProviderMap: Object
  }

  connect() {
    queueMicrotask(() => this.syncSubtypeWithProduct())
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
    this.#inflationController()?.toggleSubtypeFields()
  }

  syncIssueDateWithPurchase() {
    const purchasedOnInput = this.element.querySelector('input[name="bond_lot[purchased_on]"]')
    const issueDateInput = this.element.querySelector('input[name="bond_lot[issue_date]"]')
    if (!purchasedOnInput || !issueDateInput) return

    if (!issueDateInput.value && purchasedOnInput.value) {
      issueDateInput.value = purchasedOnInput.value
    }
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
    if (!this.hasProviderSelectTarget) return

    const providerSelect = this.providerSelectTarget

    const mappedProvider = this.productProviderMapValue?.[productCode]
    const providerDerived = mappedProvider !== undefined && mappedProvider !== null && `${mappedProvider}` !== ""

    if (providerDerived) {
      providerSelect.value = mappedProvider
    } else if (productCode) {
      providerSelect.value = ""
    }

    providerSelect.disabled = providerDerived
    this.#inflationController()?.syncAutoFetchWithProvider({ preserveExisting: true })
  }

  #inflationController() {
    return this.application.getControllerForElementAndIdentifier(this.element, "bond-lot-inflation")
  }
}
