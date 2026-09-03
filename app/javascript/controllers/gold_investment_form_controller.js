import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["subtype", "form"]

  connect() {
    this.toggle()
  }

  toggle() {
    const isGold = this.subtypeTarget.value === "gold"
    this.formTarget.classList.toggle("hidden", !isGold)
  }
}
