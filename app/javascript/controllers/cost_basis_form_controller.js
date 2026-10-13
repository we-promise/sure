import { Controller } from "@hotwired/stimulus"
import parseLocaleFloat from "utils/parse_locale_float"

// Handles bidirectional conversion between total cost basis and per-share cost
// in the manual cost basis entry form.
export default class extends Controller {
  static targets = ["total", "perShare"]
  static values = { qty: Number }

  // Called when user types in the total cost basis field
  // Updates the per-share field with the calculated value
  updatePerShare() {
    const total = parseLocaleFloat(this.totalTarget.value)
    const qty = this.qtyValue || 1
    this.perShareTarget.value = qty > 0 ? (total / qty).toFixed(2) : "0.00"
  }

  // Called when user types in the per-share field
  // Updates the total cost basis field with the calculated value
  updateTotal() {
    const perShare = parseLocaleFloat(this.perShareTarget.value)
    const qty = this.qtyValue || 1
    this.totalTarget.value = (perShare * qty).toFixed(2)
  }
}
