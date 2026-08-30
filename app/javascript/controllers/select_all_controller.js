import { Controller } from "@hotwired/stimulus"

// Simple "select all" checkbox controller
// Connect to a container, specify which checkboxes to control via target
//
// The optional "count" target receives a live tally. Both it and the
// selectedLabel/keptLabel values are optional, so existing users of this
// controller that only declare checkbox/selectAll keep working unchanged.
export default class extends Controller {
  static targets = ["checkbox", "selectAll", "count"]
  static values = { selectedLabel: String, keptLabel: String }

  connect() {
    this.refresh()
  }

  toggle(event) {
    const checked = event.target.checked
    this.checkboxTargets.forEach((checkbox) => {
      checkbox.checked = checked
    })
    this.refresh()
  }

  refresh() {
    if (!this.hasCountTarget) return

    const selected = this.checkboxTargets.filter((checkbox) => checkbox.checked).length
    const kept = this.checkboxTargets.length - selected

    this.countTarget.textContent = `${selected} ${this.selectedLabelValue} · ${kept} ${this.keptLabelValue}`
  }
}
