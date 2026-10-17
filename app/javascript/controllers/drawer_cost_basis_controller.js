import { Controller } from "@hotwired/stimulus"

// Shows/hides the inline cost basis editor in the holding drawer.
// The total <-> per-share conversion lives in cost_basis_form_controller.
export default class extends Controller {
  static targets = ["form"]

  toggle(event) {
    event.preventDefault()
    this.formTarget.classList.toggle("hidden")
  }
}
