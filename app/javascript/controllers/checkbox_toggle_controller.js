import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["selectionEntry", "toggleButton"]

  toggle() {
    const shouldShow = this.selectionEntryTargets[0].classList.contains("hidden")

    this.selectionEntryTargets.forEach((el) => {
      if (shouldShow) {
        el.classList.remove("hidden")
      } else {
        el.classList.add("hidden")
      }
    })

    if (!shouldShow) {
      const bulkSelectElement = document.querySelector("[data-controller~='bulk-select']");
      if (bulkSelectElement) {
        const bulkSelectController = this.application.getControllerForElementAndIdentifier(
          bulkSelectElement,
          "bulk-select"
        );
        if (bulkSelectController) {
          bulkSelectController.deselectAll();
        }
      }
    }

    this.toggleButtonTarget.classList.toggle("bg-surface", shouldShow)
  }
}
