import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["rowsContainer", "row", "amountInput", "remaining", "remainingContainer", "error", "submitButton", "nameInput"]
  static values = { total: Number, currency: String }

  connect() {
    this.updateRemaining()
  }

  get rowCount() {
    return this.rowTargets.length
  }

  addRow() {
    const index = this.rowCount
    const container = this.rowsContainerTarget

    const row = document.createElement("div")
    row.classList.add("p-3", "rounded-lg", "border", "border-secondary", "bg-container")
    row.dataset.splitTransactionTarget = "row"

    // Clone category select from the first row
    const existingCategorySelect = container.querySelector(".category-select-container")
    let categorySelectHTML = ""
    if (existingCategorySelect) {
      const cloned = existingCategorySelect.cloneNode(true)

      // Reset hidden input value and update name
      const hiddenInput = cloned.querySelector("input[type='hidden']")
      if (hiddenInput) {
        hiddenInput.value = ""
        hiddenInput.name = `split[splits][${index}][category_id]`
      }

      // Reset button to show placeholder text (uncategorized)
      const button = cloned.querySelector("[data-select-target='button']")
      if (button) {
        // Find the uncategorized option text from the menu
        const uncategorizedOption = cloned.querySelector("[data-value='']")
        const placeholderText = uncategorizedOption ? uncategorizedOption.dataset.filterName : "(uncategorized)"
        button.innerHTML = placeholderText
        button.setAttribute("aria-expanded", "false")
      }

      // Reset selected states in menu
      cloned.querySelectorAll("[role='option']").forEach(option => {
        option.setAttribute("aria-selected", "false")
        option.classList.remove("bg-container-inset")
        const checkIcon = option.querySelector(".check-icon")
        if (checkIcon) checkIcon.classList.add("hidden")
      })

      // Select the blank/uncategorized option
      const blankOption = cloned.querySelector("[data-value='']")
      if (blankOption) {
        blankOption.setAttribute("aria-selected", "true")
        blankOption.classList.add("bg-container-inset")
        const checkIcon = blankOption.querySelector(".check-icon")
        if (checkIcon) checkIcon.classList.remove("hidden")
      }

      // Ensure menu is hidden
      const menu = cloned.querySelector("[data-select-target='menu']")
      if (menu && !menu.classList.contains("hidden")) {
        menu.classList.add("hidden")
      }

      categorySelectHTML = cloned.outerHTML
    }

    row.innerHTML = `
      <div class="flex items-end gap-2">
        <div class="flex-1 min-w-0">
          <label class="text-xs font-medium text-secondary uppercase tracking-wide block mb-1">Name</label>
          <input type="text"
                 name="split[splits][${index}][name]"
                 placeholder="Split name"
                 class="form-field__input border border-secondary rounded-md px-2.5 py-1.5 w-full text-sm text-primary bg-container"
                 required
                 autocomplete="off"
                 data-split-transaction-target="nameInput">
        </div>
        <div class="w-28 shrink-0">
          <label class="text-xs font-medium text-secondary uppercase tracking-wide block mb-1">Amount</label>
          <input type="number"
                 name="split[splits][${index}][amount]"
                 placeholder="0.00"
                 step="0.01"
                 class="form-field__input border border-secondary rounded-md px-2.5 py-1.5 w-full text-sm text-primary bg-container"
                 required
                 autocomplete="off"
                 data-split-transaction-target="amountInput"
                 data-action="input->split-transaction#updateRemaining">
        </div>
        ${categorySelectHTML}
        <button type="button"
                class="w-8 h-8 shrink-0 flex items-center justify-center rounded-md text-secondary hover:text-primary hover:bg-surface-hover transition-colors"
                data-action="click->split-transaction#removeRow">
          <svg xmlns="http://www.w3.org/2000/svg" width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M18 6 6 18"/><path d="m6 6 12 12"/></svg>
        </button>
      </div>
    `

    container.appendChild(row)
    this.updateRemaining()
  }

  removeRow(event) {
    event.stopPropagation()
    const row = event.target.closest("[data-split-transaction-target='row']")
    if (row && this.rowCount > 1) {
      row.remove()
      this.reindexRows()
      this.updateRemaining()
    }
  }

  reindexRows() {
    this.rowTargets.forEach((row, index) => {
      // Update input names (including hidden inputs inside category select)
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
    const container = this.remainingContainerTarget

    if (balanced) {
      this.remainingTarget.classList.remove("text-destructive")
      this.remainingTarget.classList.add("text-success")
      container.classList.remove("border-destructive", "bg-red-25")
      container.classList.add("border-green-200", "bg-green-25")
    } else {
      this.remainingTarget.classList.remove("text-success")
      this.remainingTarget.classList.add("text-destructive")
      container.classList.remove("border-green-200", "bg-green-25")
      container.classList.add("border-destructive", "bg-red-25")
    }

    this.errorTarget.classList.toggle("hidden", balanced)
    this.submitButtonTarget.disabled = !balanced
  }
}
