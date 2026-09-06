import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["rateType", "offsetAccounts"]

  connect() {
    this.update()
  }

  update() {
    const visible = this.rateTypeTarget.value === "variable"
    this.offsetAccountsTarget.classList.toggle("hidden", !visible)
    this.offsetAccountsTarget.toggleAttribute("aria-hidden", !visible)
  }
}
