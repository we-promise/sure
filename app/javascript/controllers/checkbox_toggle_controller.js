import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["selectionEntry", "toggleButton"]

  toggle() {
    if (this.selectionEntryTargets.length === 0) return

    const shouldShow = this.selectionEntryTargets[0].classList.contains("hidden")

    this.selectionEntryTargets.forEach((el) => {
      if (shouldShow) {
        el.classList.remove("hidden")
      } else {
        el.classList.add("hidden")
      }
    })

    if (!shouldShow) {
      const bulkSelectElement =
        this.element.querySelector("[data-controller~='bulk-select']") ||
        this.element.closest("[data-controller~='bulk-select']") ||
        document.querySelector("[data-controller~='bulk-select']")
      if (bulkSelectElement) {
        const bulkSelectController = this.application.getControllerForElementAndIdentifier(
          bulkSelectElement,
          "bulk-select"
        )
        if (bulkSelectController) {
          bulkSelectController.deselectAll()
        }
      }
    }

    if (this.hasToggleButtonTarget) {
      this.toggleButtonTarget.classList.toggle("bg-surface", shouldShow)
    }
  }
}
