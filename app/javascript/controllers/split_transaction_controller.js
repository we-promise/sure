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

    const categorySelectHTML = this.cloneDropdownSelect(container, ".category-select-container", "category_id", index, "(uncategorized)")
    const merchantSelectHTML = this.cloneDropdownSelect(container, ".merchant-select-container", "merchant_id", index, "(none)")
    const tagSelectHTML = this.cloneTagSelect(container, index)

    row.innerHTML = `
      <div class="flex flex-wrap md:flex-nowrap items-end gap-2">
        <div class="w-full md:flex-1 md:w-auto min-w-0 md:min-w-28">
          <label class="text-xs font-medium text-secondary uppercase tracking-wide block mb-1">Name</label>
          <input type="text"
                 name="split[splits][${index}][name]"
                 placeholder="Split name"
                 class="form-field__input border border-secondary rounded-md px-2.5 py-1.5 w-full text-sm text-primary bg-container"
                 required
                 autocomplete="off"
                 data-split-transaction-target="nameInput">
        </div>
        <div class="flex-1 md:flex-none md:w-28">
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
      <div class="flex flex-wrap md:flex-nowrap items-end gap-2 mt-2">
        ${merchantSelectHTML}
        <div class="w-full md:flex-1 md:w-auto min-w-0">
          ${tagSelectHTML}
        </div>
      </div>
    `

    container.appendChild(row)
    this.updateRemaining()
  }

  // Clones a single-select dropdown (category/merchant select) from the first
  // row, resetting its hidden input, indexed field name, and selected state
  // back to blank — otherwise the clone would resubmit row 0's selection.
  cloneDropdownSelect(container, selector, fieldKey, index, blankLabelFallback) {
    const existing = container.querySelector(selector)
    if (!existing) return ""

    const cloned = existing.cloneNode(true)

    const hiddenInput = cloned.querySelector("input[type='hidden']")
    if (hiddenInput) {
      hiddenInput.value = ""
      hiddenInput.name = `split[splits][${index}][${fieldKey}]`
    }

    const button = cloned.querySelector("[data-select-target='button']")
    if (button) {
      const blankOption = cloned.querySelector("[data-value='']")
      button.innerHTML = blankOption ? blankOption.dataset.filterName : blankLabelFallback
      button.setAttribute("aria-expanded", "false")
    }

    cloned.querySelectorAll("[role='option']").forEach(option => {
      option.setAttribute("aria-selected", "false")
      option.classList.remove("bg-container-inset")
      const checkIcon = option.querySelector(".check-icon")
      if (checkIcon) checkIcon.classList.add("hidden")
    })

    const blankOption = cloned.querySelector("[data-value='']")
    if (blankOption) {
      blankOption.setAttribute("aria-selected", "true")
      blankOption.classList.add("bg-container-inset")
      const checkIcon = blankOption.querySelector(".check-icon")
      if (checkIcon) checkIcon.classList.remove("hidden")
    }

    const menu = cloned.querySelector("[data-select-target='menu']")
    if (menu && !menu.classList.contains("hidden")) {
      menu.classList.add("hidden")
    }

    return cloned.outerHTML
  }

  // Clones the DS::TagSelect widget from the first row, clearing all
  // selections and pointing its hidden inputs at the new row's index.
  cloneTagSelect(container, index) {
    const existing = container.querySelector("[data-controller~='tag-select']")
    if (!existing) return ""

    const cloned = existing.cloneNode(true)

    const fieldName = `split[splits][${index}][tag_ids][]`
    cloned.dataset.tagSelectFieldNameValue = fieldName

    const hiddenInputsContainer = cloned.querySelector("[data-tag-select-hidden-inputs]")
    if (hiddenInputsContainer) {
      hiddenInputsContainer.innerHTML = ""
      const emptyInput = document.createElement("input")
      emptyInput.type = "hidden"
      emptyInput.name = fieldName
      emptyInput.value = ""
      hiddenInputsContainer.appendChild(emptyInput)
    }

    const selectionContainer = cloned.querySelector("[data-tag-select-target='selectionContainer']")
    if (selectionContainer) {
      const placeholder = selectionContainer.dataset.placeholder || "None"
      selectionContainer.innerHTML = `<span class="text-secondary">${placeholder}</span>`
    }

    cloned.querySelectorAll("[role='option']").forEach(option => {
      option.setAttribute("aria-selected", "false")
      option.classList.remove("bg-container-inset")
      const checkIcon = option.querySelector(".check-icon")
      if (checkIcon) checkIcon.classList.add("hidden")
    })

    const menu = cloned.querySelector("[data-tag-select-target='menu']")
    if (menu && !menu.classList.contains("hidden")) {
      menu.classList.add("hidden")
    }

    return cloned.outerHTML
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
      // Update input names (including hidden inputs inside category/merchant
      // selects and the tag select's dynamically-built hidden inputs)
      row.querySelectorAll("[name]").forEach(input => {
        input.name = input.name.replace(/splits\[\d+\]/, `splits[${index}]`)
      })

      // The tag select's hidden input names are rebuilt from this Stimulus
      // value on every selection change, so it must be reindexed too.
      row.querySelectorAll("[data-tag-select-field-name-value]").forEach(el => {
        el.dataset.tagSelectFieldNameValue = el.dataset.tagSelectFieldNameValue.replace(/splits\[\d+\]/, `splits[${index}]`)
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
