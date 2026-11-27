import { Controller } from "@hotwired/stimulus"
import { precisionFromStep } from "utils/evaluate_amount_expression"
import submittedAmount from "utils/submitted_amount"

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
    // A saved row can carry more decimals than the currency, so each row is
    // read with its own precision and the balance uses the finest of them and
    // of the total, which Entry#split! must match exactly.
    let precision = Math.min((String(total).split(".")[1] || "").length, 4)
    const sum = this.amountInputTargets.reduce((acc, input) => {
      const rowPrecision = precisionFromStep(input.step) ?? 2
      precision = Math.max(precision, rowPrecision)
      // Each row as its money field submits it (rounded to its precision), so
      // "100/3" in three rows shows the 0.01 that Entry#split! will reject.
      return acc + (submittedAmount(this.application, input, rowPrecision) || 0)
    }, 0)

    const remaining = total - sum
    const balanced = Math.abs(remaining) < 0.5 * 10 ** -precision

    this.remainingTarget.textContent = (balanced ? 0 : remaining).toFixed(precision)

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
