import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = [
    "inflationFields",
    "otherFields",
    "inflationInput",
    "otherRequiredInput",
    "manualInflationField",
    "manualInflationInput",
    "subtypeInput",
    "purchasedOnInput",
    "issueDateInput"
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
      if (input.dataset.requiresFirstPeriodCheck === "true") {
        input.required = inflationLinked && firstPeriodRateRequired
      } else {
        input.required = inflationLinked && !(input.dataset.optional === "true")
      }
    })

    this.otherRequiredInputTargets.forEach((input) => {
      input.disabled = inflationLinked
      input.required = !inflationLinked
    })

    this.#toggleManualInflationField()
  }

  recalculate() {
    this.toggleSubtypeFields()
  }

  #toggleManualInflationField() {
    if (!this.hasManualInflationFieldTarget || !this.hasManualInflationInputTarget) return

    const inflationLinked = this.inflationSubtypesValue.includes(this.#subtypeValue())

    this.manualInflationFieldTarget.classList.toggle("hidden", !inflationLinked)
    this.manualInflationInputTarget.disabled = !inflationLinked
    this.manualInflationInputTarget.required = inflationLinked
  }

  #subtypeValue() {
    return this.hasSubtypeInputTarget ? `${this.subtypeInputTarget.value || ""}` : ""
  }

  #firstPeriodRateRequired() {
    const purchasedOn = this.#parseDate(this.hasPurchasedOnInputTarget ? this.purchasedOnInputTarget.value : null)
    const issueDate = this.#parseDate(this.hasIssueDateInputTarget ? this.issueDateInputTarget.value : null)

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