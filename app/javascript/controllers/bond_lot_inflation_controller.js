import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = [
    "inflationFields",
    "otherFields",
    "inflationInput",
    "otherRequiredInput",
    "autoFetchInput",
    "manualInflationField",
    "manualInflationInput"
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
    const autoFetch = this.#currentAutoFetchValue()
    const showManualField = inflationLinked && (!autoFetch || !this.globalImportEnabledValue)
    const required = inflationLinked && !autoFetch

    this.manualInflationFieldTarget.classList.toggle("hidden", !showManualField)
    this.manualInflationInputTarget.disabled = !showManualField
    this.manualInflationInputTarget.required = required
  }

  /**
   * Synchronizes auto-fetch state with the selected inflation provider.
   * Called as a Stimulus action (Event) or programmatically from
   * bond_lot_form_controller.js with { preserveExisting: true }.
   * @param {Event|{preserveExisting?: boolean}} [options]
   */
  syncAutoFetchWithProvider(options = {}) {
    if (!this.globalImportEnabledValue) return
    if (!this.hasAutoFetchInputTarget) return

    const preserveExisting = Boolean(options?.preserveExisting)

    if (preserveExisting) {
      if (this.autoFetchInputTarget.type === "checkbox") {
        if (this.autoFetchInputTarget.checked) {
          this.toggleManualInflationField()
          return
        }
      } else {
        const currentValue = `${this.autoFetchInputTarget.value || ""}`.trim()
        if (currentValue !== "") {
          this.toggleManualInflationField()
          return
        }
      }
    }

    const provider = this.#providerValue()
    if (this.autoFetchInputTarget.type === "checkbox") {
      this.autoFetchInputTarget.checked = provider !== ""
    } else {
      this.autoFetchInputTarget.value = provider === "" ? "0" : "1"
    }

    this.toggleManualInflationField()
  }

  #subtypeValue() {
    const input = this.element.querySelector('select[name="bond_lot[subtype]"]')
    return `${input?.value || ""}`
  }

  #providerValue() {
    const input = this.element.querySelector('select[name="bond_lot[inflation_provider]"]')
    return `${input?.value || ""}`.trim()
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