import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = [
    "productCodeSelect",
    "subtypeSelect",
    "subtypeDerivedHint",
    "purchasedOnInput",
    "issueDateInput",
    "termInput"
  ]
  static values = {
    productSubtypeMap: Object,
    productTermMap: Object
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
    this.#inflationController()?.toggleSubtypeFields()
  }

  syncIssueDateWithPurchase() {
    if (!this.hasPurchasedOnInputTarget || !this.hasIssueDateInputTarget) return

    if (!this.issueDateInputTarget.value && this.purchasedOnInputTarget.value) {
      this.issueDateInputTarget.value = this.purchasedOnInputTarget.value
    }
  }

  #syncTermWithProduct(productCode) {
    if (!this.hasTermInputTarget) return

    const mappedTerm = this.productTermMapValue?.[productCode]
    const termDerived = mappedTerm !== undefined && mappedTerm !== null && `${mappedTerm}` !== ""

    if (termDerived) {
      this.termInputTarget.value = mappedTerm
    }

    this.termInputTarget.readOnly = termDerived
  }

  #inflationController() {
    return this.application.getControllerForElementAndIdentifier(this.element, "bond-lot-inflation")
  }
}
