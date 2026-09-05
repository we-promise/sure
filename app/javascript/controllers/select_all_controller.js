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
    const selected = this.checkboxTargets.filter((checkbox) => checkbox.checked).length
    const kept = this.checkboxTargets.length - selected

    // Keep the master checkbox honest once individual boxes are unticked. Pages
    // that drive this controller with a plain checkbox (no selectAll target) are
    // unaffected.
    if (this.hasSelectAllTarget) {
      this.selectAllTarget.checked = selected > 0 && kept === 0
      this.selectAllTarget.indeterminate = selected > 0 && kept > 0
    }

    if (!this.hasCountTarget) return

    this.countTarget.textContent = `${selected} ${this.selectedLabelValue} · ${kept} ${this.keptLabelValue}`
  }
}
