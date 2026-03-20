import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["rowsContainer", "row", "amountInput", "remaining", "error", "submitButton", "nameInput"]
  static values = { total: Number, currency: String }

  get rowCount() {
    return this.rowTargets.length
  }

  addRow() {
    const index = this.rowCount
    const number = index + 1
    const container = this.rowsContainerTarget

    // Clone category options from the first row's select
    const existingSelect = container.querySelector("select")
    const categoryOptions = existingSelect ? existingSelect.innerHTML : '<option value="">(uncategorized)</option>'

    const row = document.createElement("div")
    row.classList.add("p-3", "rounded-lg", "border", "border-secondary", "bg-container", "space-y-3")
    row.dataset.splitTransactionTarget = "row"

    row.innerHTML = `
      <div class="flex items-center justify-between">
        <span class="text-xs font-medium text-secondary uppercase tracking-wide">Split #${number}</span>
        <button type="button"
                class="p-1 rounded text-secondary hover:text-primary hover:bg-surface-inset transition-colors"
                data-action="click->split-transaction#removeRow">
          <svg xmlns="http://www.w3.org/2000/svg" width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M18 6 6 18"/><path d="m6 6 12 12"/></svg>
        </button>
      </div>
      <div class="space-y-1">
        <label class="font-medium text-sm text-primary block">Name</label>
        <input type="text"
               name="split[splits][${index}][name]"
               placeholder="Split name"
               class="form-field__input border border-secondary rounded-lg px-3 py-2 w-full text-primary bg-container"
               required
               autocomplete="off"
               data-split-transaction-target="nameInput">
      </div>
      <div class="grid grid-cols-2 gap-3">
        <div class="space-y-1">
          <label class="font-medium text-sm text-primary block">Amount</label>
          <input type="number"
                 name="split[splits][${index}][amount]"
                 placeholder="0.00"
                 step="0.01"
                 class="form-field__input border border-secondary rounded-lg px-3 py-2 w-full text-primary bg-container"
                 required
                 autocomplete="off"
                 data-split-transaction-target="amountInput"
                 data-action="input->split-transaction#updateRemaining">
        </div>
        <div class="space-y-1">
          <label class="font-medium text-sm text-primary block">Category</label>
          <select name="split[splits][${index}][category_id]"
                  class="form-field__input border border-secondary rounded-lg px-3 py-2 w-full text-primary bg-container">
            ${categoryOptions}
          </select>
        </div>
      </div>
    `

    container.appendChild(row)
    this.updateRemaining()
  }

  removeRow(event) {
    const row = event.target.closest("[data-split-transaction-target='row']")
    if (row && this.rowCount > 1) {
      row.remove()
      this.reindexRows()
      this.updateRemaining()
    }
  }

  reindexRows() {
    this.rowTargets.forEach((row, index) => {
      // Update the split number header
      const header = row.querySelector(".text-xs.font-medium")
      if (header) {
        header.textContent = `Split #${index + 1}`
      }

      // Update input names
      row.querySelectorAll("[name]").forEach(input => {
        input.name = input.name.replace(/splits\[\d+\]/, `splits[${index}]`)
      })
    })
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
    if (balanced) {
      this.remainingTarget.classList.remove("text-destructive")
      this.remainingTarget.classList.add("text-success")
    } else {
      this.remainingTarget.classList.remove("text-success")
      this.remainingTarget.classList.add("text-primary")
    }

    this.errorTarget.classList.toggle("hidden", balanced)
    this.submitButtonTarget.disabled = !balanced
  }
}
