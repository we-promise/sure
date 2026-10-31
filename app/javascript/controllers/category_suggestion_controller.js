import { Controller } from "@hotwired/stimulus"

// Applies the category most commonly used on a past transaction when the user picks
// that transaction's name from the description autocomplete, and clears it again if a
// later-picked name has no usual category of its own. A manual category pick always
// wins over the suggestion, even if the name field changes afterward.
export default class extends Controller {
  static targets = ["categoryField", "name"]

  connect() {
    // A category already present when the controller connects (e.g. prefilled from
    // duplicating an existing transaction) is a deliberate default — treat it the same
    // as a manual pick so suggestions never clobber it.
    this.userPickedCategory = this.#hasCategorySelection()
    this.applyingSuggestion = false
  }

  syncName(event) {
    // Async combobox options can arrive after submission. The visible free-text
    // value, including an intentional blank, is authoritative for the name.
    event.formData.set("entry[name]", this.nameTarget.value)
  }

  onCategorySelected(event) {
    if (this.applyingSuggestion) return
    if (!event.target.matches('[data-category-select-target="hiddenInput"]')) return

    this.userPickedCategory = true
  }

  onNameSuggestionSelected(event) {
    // Leaving the field after typing part of a name also fires a selection for the
    // highlighted option; only a name actually picked from the list carries a category.
    const { value, display } = event.detail
    if (!value || value !== display) return

    const option = event.target.querySelector(`[role="option"][data-value="${CSS.escape(value)}"]`)
    const categoryId = option?.querySelector("[data-category-id]")?.dataset.categoryId

    // A name with no usual category (categoryId undefined) still needs to clear a category
    // that was auto-applied for a previously selected name — otherwise it stays attached to
    // the new, unrelated name. #selectCategoryOption already leaves a manual pick untouched.
    this.#selectCategoryOption(categoryId || "")
  }

  #hasCategorySelection() {
    return !!this.#categoryHiddenInput()?.value
  }

  #categoryHiddenInput() {
    return this.hasCategoryFieldTarget
      ? this.categoryFieldTarget.querySelector('[data-category-select-target="hiddenInput"]')
      : null
  }

  #selectCategoryOption(categoryId) {
    if (this.userPickedCategory || !this.hasCategoryFieldTarget) return

    const option = this.categoryFieldTarget.querySelector(
      `[data-category-select-target="option"][data-category-id="${CSS.escape(String(categoryId))}"]`
    )
    if (!option) return

    this.applyingSuggestion = true
    option.click()
    this.applyingSuggestion = false
  }
}
