import { Controller } from "@hotwired/stimulus"

// Drives the single move dialog shared by every category row on the budget
// allocation page. One dialog for the page rather than one per row: the list
// can hold dozens of categories, and they would all be identical but for the
// source.
//
// Options that the server would refuse anyway are disabled rather than left
// selectable — a category cannot send money to itself, nor to its own parent
// or child, because the parent's allocation is derived from its children's.
export default class extends Controller {
  static targets = ["dialog", "fromId", "fromName", "available", "toSelect", "amount"]

  open({ params }) {
    this.fromIdTarget.value = params.fromId
    this.fromNameTarget.textContent = params.fromName
    this.availableTarget.textContent = params.available
    this.amountTarget.value = ""

    this.#refreshOptions(String(params.fromId), String(params.categoryId), String(params.parentId || ""))
    this.dialogTarget.showModal()
    this.amountTarget.focus()
  }

  close() {
    this.dialogTarget.close()
  }

  #refreshOptions(fromId, categoryId, parentId) {
    let firstEnabled = null

    for (const option of this.toSelectTarget.options) {
      const optionCategoryId = option.dataset.categoryId
      const optionParentId = option.dataset.parentId || ""

      option.disabled =
        option.value === fromId ||
        optionCategoryId === parentId ||
        optionParentId === categoryId

      if (!option.disabled && firstEnabled === null) firstEnabled = option
    }

    if (firstEnabled) this.toSelectTarget.value = firstEnabled.value
  }
}
