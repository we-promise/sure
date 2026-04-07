import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["button"]

  updateButton(event) {
    const { value } = event.detail
    const option = this.element.querySelector(`[role="option"][data-value="${CSS.escape(value)}"]`)
    if (!option) return

    const badge = option.querySelector("span.flex.items-center")
    if (badge) {
      this.buttonTarget.innerHTML = badge.outerHTML
    } else {
      this.buttonTarget.textContent = option.dataset.filterName || option.textContent.trim()
    }
  }
}
