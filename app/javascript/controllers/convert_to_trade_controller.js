import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["customWrapper", "customField", "tickerSelect"]

  toggleCustomTicker(event) {
    const value = event.target.value

    if (value === "__custom__") {
      // Show custom ticker field
      this.customWrapperTarget.classList.remove("hidden")
      this.customFieldTarget.required = true
      this.customFieldTarget.focus()
    } else {
      // Hide custom ticker field
      this.customWrapperTarget.classList.add("hidden")
      this.customFieldTarget.required = false
      this.customFieldTarget.value = ""
    }
  }
}
