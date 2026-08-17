import { Controller } from "@hotwired/stimulus"

// Applies the category most commonly used on a past transaction when the user picks
// that transaction's name from the "Libellé" autocomplete. A manual category pick
// always wins over the suggestion, even if the name field changes afterward.
export default class extends Controller {
  static targets = ["categoryField"]

  connect() {
    this.userPickedCategory = false
    this.applyingSuggestion = false
  }

  onCategorySelected() {
    if (this.applyingSuggestion) return
    this.userPickedCategory = true
  }

  onNameSuggestionSelected(event) {
    const { value } = event.detail
    if (!value) return

    const option = event.target.querySelector(`[role="option"][data-value="${CSS.escape(value)}"]`)
    const categoryId = option?.querySelector("[data-category-id]")?.dataset.categoryId
    if (categoryId) this.applySuggestion(categoryId)
  }

  hasCategorySelection() {
    return !!this.categoryHiddenInput()?.value
  }

  categoryHiddenInput() {
    return this.hasCategoryFieldTarget
      ? this.categoryFieldTarget.querySelector('[data-form-dropdown-target="input"]')
      : null
  }

  applySuggestion(categoryId) {
    if (this.userPickedCategory || this.hasCategorySelection() || !this.hasCategoryFieldTarget) return

    const option = this.categoryFieldTarget.querySelector(
      `[data-select-target="option"][data-value="${CSS.escape(String(categoryId))}"]`
    )
    if (!option) return

    this.applyingSuggestion = true
    option.click()
    this.applyingSuggestion = false
  }
}
