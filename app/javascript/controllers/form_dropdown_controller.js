import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["input"]

  onSelect(event) {
    // Selects that start disabled to signal "untouched" become submittable
    // as soon as the user picks any option, including the blank "(none)".
    this.inputTarget.disabled = false
    this.inputTarget.value = event.detail.value

    const inputEvent = new Event("input", { bubbles: true })
    this.inputTarget.dispatchEvent(inputEvent)

    const changeEvent = new Event("change", { bubbles: true })
    this.inputTarget.dispatchEvent(changeEvent)

    const form = this.element.closest("form")
    const controllers = (form?.dataset.controller || "").split(/\s+/)
    if (form && controllers.includes("auto-submit-form")) {
      form.requestSubmit()
    }
  }
}
