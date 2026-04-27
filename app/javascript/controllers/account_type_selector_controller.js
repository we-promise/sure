import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["subtypeContainer", "typeFields"]
  static values = { accountId: String }

  connect() {
    this.updateSubtype()
  }

  toggleInclude(event) {
    if (this.hasTypeFieldsTarget) {
      this.typeFieldsTarget.style.display = event.target.checked ? "" : "none"
    }
  }

  updateSubtype(event) {
    const selectElement = this.element.querySelector('select[name^="account_types"]')
    const selectedType = selectElement ? selectElement.value : ''
    const container = this.subtypeContainerTarget
    const accountId = this.accountIdValue

    const subtypeSelects = container.querySelectorAll('.subtype-select')
    subtypeSelects.forEach(select => {
      select.style.display = 'none'
      const sel = select.querySelector('select')
      if (sel) sel.removeAttribute('name')
    })

    const relevantSubtype = container.querySelector(`[data-type="${selectedType}"]`)
    if (relevantSubtype) {
      relevantSubtype.style.display = 'block'
      const sel = relevantSubtype.querySelector('select')
      if (sel) sel.setAttribute('name', `account_subtypes[${accountId}]`)
    }
  }
}
