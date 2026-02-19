import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["input"]

  connect() {
    this.element.addEventListener("dropdown:select", (event) => {
      this.inputTarget.value = event.detail.value

      const changeEvent = new Event("change", { bubbles: true })
      this.inputTarget.dispatchEvent(changeEvent)

      const form = this.element.closest("form")
      if (form && form.dataset.controller?.includes("auto-submit-form")) {
        form.requestSubmit()
      }
    })
  }
}
