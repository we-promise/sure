import { Controller } from "@hotwired/stimulus"

// Shows/hides the inline cost basis editor in the holding drawer.
// The total <-> per-share conversion lives in cost_basis_form_controller.
export default class extends Controller {
  static targets = ["form", "opener"]

  // Opening moves focus into the editor, closing (pencil or Cancel) returns it
  // to the pencil, so focus never drops to <body> with the hidden form.
  toggle(event) {
    event.preventDefault()
    const hidden = this.formTarget.classList.toggle("hidden")

    if (hidden) {
      this.openerTarget.focus()
    } else {
      this.formTarget.querySelector("input:not([type='hidden'])")?.focus()
    }
  }
}
