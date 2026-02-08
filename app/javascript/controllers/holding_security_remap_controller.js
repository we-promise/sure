import { Controller } from "@hotwired/stimulus"

// Handles toggling the security remap form in the holding drawer.
export default class extends Controller {
  static targets = ["form"]

  toggle(event) {
    event.preventDefault()
    this.formTarget.classList.toggle("hidden")
  }
}
