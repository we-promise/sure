import { Controller } from "@hotwired/stimulus"

// Handles the inline cost basis editor in the holding drawer.
// Shows/hides the form and handles bidirectional total <-> per-share conversion.
export default class extends Controller {
  static targets = ["form", "total", "perShare", "perShareValue"]
  static values = { qty: Number }

  toggle(event) {
    event.preventDefault()
    this.formTarget.classList.toggle("hidden")
  }

  // Called when user types in total cost basis field
  updatePerShare() {
    const total = Number.parseFloat(this.totalTarget.value) || 0
    const qty = this.qtyValue || 1
    const perShare = qty > 0 ? (total / qty).toFixed(2) : "0.00"
    this.perShareValueTarget.textContent = perShare
    if (this.hasPerShareTarget) {
      this.perShareTarget.value = perShare
    }
  }

  // Called when user types in per-share field
  updateTotal() {
    const perShare = Number.parseFloat(this.perShareTarget.value) || 0
    const qty = this.qtyValue || 1
    const total = (perShare * qty).toFixed(2)
    this.totalTarget.value = total
    this.perShareValueTarget.textContent = perShare.toFixed(2)
  }
}
