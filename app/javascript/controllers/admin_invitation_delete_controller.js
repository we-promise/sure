import { Controller } from "@hotwired/stimulus"

// Connects to data-controller="admin-invitation-delete"
// Handles individual invitation deletion and alt-click to delete all family invitations
export default class extends Controller {
  static targets = [ "button", "destroyAllForm" ]
  static values = { deleteAllLabel: String }

  handleClick(event) {
    if (event.altKey) {
      event.preventDefault()

      this.buttonTargets.forEach(btn => {
        btn.textContent = this.deleteAllLabelValue
      })

      if (this.hasDestroyAllFormTarget) {
        this.destroyAllFormTarget.requestSubmit()
      }
    }
  }
}
