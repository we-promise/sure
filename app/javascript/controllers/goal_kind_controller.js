import { Controller } from "@hotwired/stimulus"

// A maintained reserve has no deadline: it is a level to hold, not something
// due on a date. Hiding the target-date field keeps a stale value from being
// submitted and driving a pace the goal does not have.
export default class extends Controller {
  static targets = ["radio", "dateField"]

  connect() {
    this.refresh()
  }

  refresh() {
    const maintained = this.radioTargets.some((radio) => radio.checked && radio.value === "maintained")
    this.dateFieldTargets.forEach((field) => field.classList.toggle("hidden", maintained))
    if (maintained) {
      this.dateFieldTargets.forEach((field) => {
        const input = field.querySelector("input")
        if (!input) return

        input.value = ""
        // Assigning `value` fires nothing, so the pace suggestion bound to
        // this input's action kept showing a monthly figure derived from a
        // deadline the goal no longer has.
        input.dispatchEvent(new Event("input", { bubbles: true }))
      })
    }
  }
}
