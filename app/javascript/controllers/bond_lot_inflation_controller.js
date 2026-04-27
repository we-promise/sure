import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = [
    "inflationFields",
    "otherFields",
    "inflationInput",
    "otherRequiredInput",
    "manualInflationField",
    "manualInflationInput"
  ]

  static values = {
    inflationSubtypes: Array
  }

  connect() {
    this.toggleSubtypeFields()
  }

  toggleSubtypeFields() {
    const subtype = this.#subtypeValue()
    const inflationLinked = this.inflationSubtypesValue.includes(subtype)
    const firstPeriodRateRequired = this.#firstPeriodRateRequired()

    this.inflationFieldsTargets.forEach((element) => {
      element.classList.toggle("hidden", !inflationLinked)
    })

    this.otherFieldsTargets.forEach((element) => {
      element.classList.toggle("hidden", inflationLinked)
    })

    this.inflationInputTargets.forEach((input) => {
      input.disabled = !inflationLinked
      if (input.dataset.requiresFirstPeriodCheck) {
        input.required = inflationLinked && firstPeriodRateRequired
      } else {
        input.required = inflationLinked && !input.dataset.optional
      }
    })

    this.otherRequiredInputTargets.forEach((input) => {
      input.disabled = inflationLinked
      input.required = !inflationLinked
    })

    this.toggleManualInflationField()
  }

  toggleManualInflationField() {
    if (!this.hasManualInflationFieldTarget || !this.hasManualInflationInputTarget) return

    const inflationLinked = this.inflationSubtypesValue.includes(this.#subtypeValue())

    this.manualInflationFieldTarget.classList.toggle("hidden", !inflationLinked)
    this.manualInflationInputTarget.disabled = !inflationLinked
    this.manualInflationInputTarget.required = inflationLinked
  }

  #subtypeValue() {
    const input = this.element.querySelector('select[name="bond_lot[subtype]"]')
    return `${input?.value || ""}`
  }

  #firstPeriodRateRequired() {
    const purchasedOnInput = this.element.querySelector('input[name="bond_lot[purchased_on]"]')
    const issueDateInput = this.element.querySelector('input[name="bond_lot[issue_date]"]')
    const purchasedOn = this.#parseDate(purchasedOnInput?.value)
    const issueDate = this.#parseDate(issueDateInput?.value)

    if (!purchasedOn) return false

    const baseDate = issueDate || purchasedOn
    const firstPeriodEnd = new Date(baseDate)
    firstPeriodEnd.setFullYear(firstPeriodEnd.getFullYear() + 1)

    return purchasedOn < firstPeriodEnd
  }

  #parseDate(value) {
    if (!value) return null
    const parsed = new Date(value)
    return Number.isNaN(parsed.getTime()) ? null : parsed
  }

}