import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["input"]

  onSelect(event) {
    this.inputTarget.value = event.detail.value

    const inputEvent = new Event("input", { bubbles: true })
    this.inputTarget.dispatchEvent(inputEvent)

    const form = this.element.closest("form")
    const controllers = (form?.dataset.controller || "").split(/\s+/)
    if (form && controllers.includes("auto-submit-form")) {
      form.requestSubmit()
    }
  }
}
