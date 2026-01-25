import { Controller } from "@hotwired/stimulus"

// Simple "select all" checkbox controller
// Connect to a container, specify which checkboxes to control via target
export default class extends Controller {
  static targets = ["checkbox", "selectAll"]

  toggle(event) {
    const checked = event.target.checked
    this.checkboxTargets.forEach((checkbox) => {
      checkbox.checked = checked
    })
  }
}
