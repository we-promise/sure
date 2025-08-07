import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["subtypeContainer"]
  static values = { accountId: String }

  connect() {
    // Show initial subtype dropdown based on current selection
    this.updateSubtype()
  }

  updateSubtype(event) {
    const selectElement = this.element.querySelector('select[name^="account_types"]')
    const selectedType = selectElement ? selectElement.value : ''
    const container = this.subtypeContainerTarget
    const accountId = this.accountIdValue
    
    // Hide all subtype selects
    const subtypeSelects = container.querySelectorAll('.subtype-select')
    subtypeSelects.forEach(select => {
      select.style.display = 'none'
      // Clear the name attribute so it doesn't get submitted
      const selectElement = select.querySelector('select')
      if (selectElement) {
        selectElement.removeAttribute('name')
      }
    })
    
   // Don't show any subtype select for Skip option
   if (selectedType === 'Skip') {
    return
  }

    // Show the relevant subtype select
    const relevantSubtype = container.querySelector(`[data-type="${selectedType}"]`)
    if (relevantSubtype) {
      relevantSubtype.style.display = 'block'
      // Re-add the name attribute so it gets submitted
      const selectElement = relevantSubtype.querySelector('select')
      if (selectElement) {
        selectElement.setAttribute('name', `account_subtypes[${accountId}]`)
      }
    }
  }
}