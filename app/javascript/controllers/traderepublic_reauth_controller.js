import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["buttonText", "spinner"]

  submit(event) {
    // Don't prevent default - let the form submit
    
    // Show spinner and update text
    if (this.hasButtonTextTarget) {
      this.buttonTextTarget.textContent = "Sending code..."
    }
    
    if (this.hasSpinnerTarget) {
      this.spinnerTarget.classList.remove("hidden")
    }
    
    // Disable the button to prevent double-clicks
    event.currentTarget.disabled = true
  }
}
