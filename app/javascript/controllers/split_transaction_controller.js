import { Controller } from "@hotwired/stimulus"

// Split rows are real, individually-named form fields rendered server-side (via the
// "splits/row" partial) and cloned from a <template> for new rows — mirrors
// rule--split-action, which took the same approach after a hand-rolled JS-serialized
// blob proved fragile in practice. Cloning from the template means new rows automatically
// pick up whatever fields the partial renders (category/merchant/tag selects included)
// without this controller needing to know about them.
export default class extends Controller {
  static targets = ["rowsContainer", "row", "rowTemplate", "amountInput", "remaining", "remainingContainer", "error", "submitButton", "nameInput"]
  static values = { total: Number, currency: String }

  connect() {
    this.updateRemaining()
  }

  get rowCount() {
    return this.rowTargets.length
  }

  addRow() {
    // Seeded from Date.now() (so it can't collide with existing server-rendered row indices,
    // e.g. 0/1/2 for an already-split transaction's children) but incremented monotonically
    // from there — two rows added within the same millisecond would otherwise get the same
    // index, producing duplicate field names that silently drop one row.
    this.nextRowIndex ??= Date.now()
    const html = this.rowTemplateTarget.innerHTML.replaceAll("ROW_IDX_PLACEHOLDER", this.nextRowIndex++)
    this.rowsContainerTarget.insertAdjacentHTML("beforeend", html)
    this.updateRemaining()
  }

  removeRow(event) {
    event.stopPropagation()
    const row = event.target.closest("[data-split-transaction-target='row']")
    if (row && this.rowCount > 1) {
      row.remove()
      this.updateRemaining()
    }
  }

  updateRemaining() {
    const total = this.totalValue
    const sum = this.amountInputTargets.reduce((acc, input) => {
      return acc + (Number.parseFloat(input.value) || 0)
    }, 0)

    const remaining = total - sum
    const absRemaining = Math.abs(remaining)
    const balanced = absRemaining < 0.005

    this.remainingTarget.textContent = balanced ? "0.00" : remaining.toFixed(2)

    // Visual feedback on remaining balance
    const container = this.remainingContainerTarget

    if (balanced) {
      this.remainingTarget.classList.remove("text-destructive")
      this.remainingTarget.classList.add("text-success")
      container.classList.remove("border-destructive", "bg-red-tint-10")
      container.classList.add("border-green-200", "bg-green-tint-10")
    } else {
      this.remainingTarget.classList.remove("text-success")
      this.remainingTarget.classList.add("text-destructive")
      container.classList.remove("border-green-200", "bg-green-tint-10")
      container.classList.add("border-destructive", "bg-red-tint-10")
    }

    this.errorTarget.classList.toggle("hidden", balanced)
    this.submitButtonTarget.disabled = !balanced
  }
}
