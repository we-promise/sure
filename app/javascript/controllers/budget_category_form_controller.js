import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["frequency", "monthlyField", "annualField", "budgetedSpending", "annualAmount", "monthlyNote"]

  frequencyChanged() {
    const isMonthly = this.frequencyTarget.value === "monthly"

    if (isMonthly) {
      this.monthlyFieldTarget.classList.remove("hidden")
      this.annualFieldTarget.classList.add("hidden")
    } else {
      this.monthlyFieldTarget.classList.add("hidden")
      this.annualFieldTarget.classList.remove("hidden")
    }

    if (this.hasMonthlyNoteTarget) {
      this.monthlyNoteTarget.classList.toggle("hidden", isMonthly)
    }
  }
}
