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

    const monthlyRate = (annualRate / 100) / 12

    let emi
    if (monthlyRate === 0) {
      emi = principal / tenure
    } else {
      const factor = (1 + monthlyRate) ** tenure
      emi = (principal * monthlyRate * factor) / (factor - 1)
    }

    const totalPayments = emi * tenure
    const totalInterest = Math.max(totalPayments - principal, 0)
    const totalPayable = totalPayments + fee

    this.monthlyAmountTarget.textContent = this.formatMoney(emi)
    this.totalInterestTarget.textContent = this.formatMoney(totalInterest)
    this.totalPayableTarget.textContent = this.formatMoney(totalPayable)
  }

  formatMoney(value) {
    try {
      return new Intl.NumberFormat(undefined, { style: "currency", currency: this.currencyValue || "USD" }).format(value)
    } catch {
      return value.toFixed(2)
    }
  }
}
