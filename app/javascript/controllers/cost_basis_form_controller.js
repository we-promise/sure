import { Controller } from "@hotwired/stimulus"

// Handles bidirectional conversion between total cost basis and per-share cost
// in the manual cost basis entry form.
export default class extends Controller {
  static targets = ["total", "perShare", "perShareValue"]
  static values = { qty: Number }

  // Called when user types in the total cost basis field
  // Updates the per-share display and input to show the calculated value
  updatePerShare() {
    const total = Number.parseFloat(this.totalTarget.value) || 0
    const qty = this.qtyValue || 1
    const perShare = qty > 0 ? (total / qty).toFixed(2) : "0.00"
    this.perShareValueTarget.textContent = perShare
    if (this.hasPerShareTarget) {
      this.perShareTarget.value = perShare
    }
  }

  // Called when user types in the per-share field
  // Updates the total cost basis field with the calculated value
  updateTotal() {
    const perShare = Number.parseFloat(this.perShareTarget.value) || 0
    const qty = this.qtyValue || 1
    const total = (perShare * qty).toFixed(2)
    this.totalTarget.value = total
    this.perShareValueTarget.textContent = perShare.toFixed(2)
  }
}
