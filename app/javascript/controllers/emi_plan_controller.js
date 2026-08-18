import { Controller } from "@hotwired/stimulus"

// Connects to data-controller="emi-plan"
// Mirrors the server-side EmiPlan#amortization_schedule math so the modal
// can show a live preview before the user submits the form.
export default class extends Controller {
  static targets = ["tenureInput", "interestInput", "feeInput", "startDateInput", "monthlyAmount", "totalInterest", "totalPayable"]
  static values = { principal: Number, currency: String }

  connect() {
    this.recalculate()
  }

  recalculate() {
    const principal = Math.abs(this.principalValue)
    const tenure = Math.max(1, Number.parseInt(this.tenureInputTarget.value, 10) || 0)
    const annualRate = Number.parseFloat(this.interestInputTarget.value) || 0
    const fee = Number.parseFloat(this.feeInputTarget.value) || 0

    if (!tenure) {
      this.monthlyAmountTarget.textContent = "—"
      this.totalInterestTarget.textContent = "—"
      this.totalPayableTarget.textContent = "—"
      return
    }

    // Mirrors EmiPlan#amortization_schedule cent-for-cent: same formula,
    // same per-row rounding, same "last installment absorbs the remainder"
    // rule. Keeping this in lockstep with the server means the preview
    // shown here matches exactly what gets persisted on submit.
    const monthlyRate = (annualRate / 100) / 12

    let emi
    if (monthlyRate === 0) {
      emi = this.roundCents(principal / tenure)
    } else {
      const factor = (1 + monthlyRate) ** tenure
      emi = this.roundCents((principal * monthlyRate * factor) / (factor - 1))
    }

    let remainingPrincipal = principal
    let totalInterest = 0
    let totalPrincipal = 0

    for (let number = 1; number <= tenure; number++) {
      const isLast = number === tenure
      let principalComponent
      let interestComponent

      if (isLast) {
        principalComponent = remainingPrincipal
        interestComponent = monthlyRate === 0 ? 0 : emi - principalComponent
      } else {
        interestComponent = monthlyRate === 0 ? 0 : this.roundCents(remainingPrincipal * monthlyRate)
        principalComponent = emi - interestComponent
      }

      interestComponent = this.roundCents(Math.max(interestComponent, 0))
      principalComponent = this.roundCents(principalComponent)
      remainingPrincipal = this.roundCents(remainingPrincipal - principalComponent)

      totalInterest = this.roundCents(totalInterest + interestComponent)
      totalPrincipal = this.roundCents(totalPrincipal + principalComponent)
    }

    const totalPayable = this.roundCents(totalPrincipal + totalInterest + fee)

    this.monthlyAmountTarget.textContent = this.formatMoney(emi)
    this.totalInterestTarget.textContent = this.formatMoney(totalInterest)
    this.totalPayableTarget.textContent = this.formatMoney(totalPayable)
  }

  // Half-up rounding to 2 decimals, matching Ruby BigDecimal#round(2)'s
  // default mode. Plain toFixed()/Math.round() can drift on floating-point
  // values that land near a cent boundary (e.g. banker's rounding in some
  // engines), which is exactly the kind of mismatch this preview exists to avoid.
  roundCents(value) {
    return Math.round((value + Number.EPSILON) * 100) / 100
  }

  formatMoney(value) {
    try {
      return new Intl.NumberFormat(undefined, { style: "currency", currency: this.currencyValue || "USD" }).format(value)
    } catch {
      return value.toFixed(2)
    }
  }
}
