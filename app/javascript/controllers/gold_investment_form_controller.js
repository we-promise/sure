import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["subtype", "form", "goldForm"]

  connect() {
    this.toggle()
  }

  toggle() {
    const isGold = this.subtypeTarget.value === "gold"
    this.formTarget.classList.toggle("hidden", !isGold)
    this.goldFormTarget.disabled = !isGold
  }
}
