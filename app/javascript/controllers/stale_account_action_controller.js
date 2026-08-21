import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["moveRadio", "targetSelect"]
  static values = { accountId: String }

  connect() {
    this.updateTargetVisibility()
  }

  updateTargetVisibility() {
    if (!this.hasTargetSelectTarget || !this.hasMoveRadioTarget) return

    const moveRadio = this.moveRadioTarget
    const targetSelect = this.targetSelectTarget

    if (moveRadio?.checked) {
      targetSelect.disabled = false
      targetSelect.classList.remove("opacity-50", "cursor-not-allowed")
    } else {
      targetSelect.disabled = true
      targetSelect.classList.add("opacity-50", "cursor-not-allowed")
    }
  }
}
