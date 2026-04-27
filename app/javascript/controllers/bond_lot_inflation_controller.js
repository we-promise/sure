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
    const el = this.element.querySelector("[data-subtype-field]")
    return el ? `${el.value || ""}` : ""
  }

  #firstPeriodRateRequired() {
    const poEl = this.element.querySelector("[data-purchased-on-field]")
    const idEl = this.element.querySelector("[data-issue-date-field]")
    const purchasedOn = this.#parseDate(poEl ? poEl.value : null)
    const issueDate = this.#parseDate(idEl ? idEl.value : null)

    if (!purchasedOn) return false

    const baseDate = issueDate || purchasedOn
    const firstPeriodEnd = new Date(baseDate)
    firstPeriodEnd.setFullYear(firstPeriodEnd.getFullYear() + 1)

    return purchasedOn < firstPeriodEnd
  }

  #parseDate(value) {
    if (!value) return null
    const match = value.match(/^(\d{4})-(\d{2})-(\d{2})$/)
    if (!match) return null
    const parsed = new Date(Number(match[1]), Number(match[2]) - 1, Number(match[3]))
    return Number.isNaN(parsed.getTime()) ? null : parsed
  }

}