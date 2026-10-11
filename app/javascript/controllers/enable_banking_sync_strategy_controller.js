import { Controller } from "@hotwired/stimulus"

// "Longest" requests full available history and has no bearing on a specific
// date, so the date field is disabled (not just hidden) while it's selected —
// a disabled input isn't submitted, so a stale date can't linger behind a
// strategy the user no longer chose.
export default class extends Controller {
  static targets = ["radio", "dateField"]

  connect() {
    this.refresh()
  }

  refresh() {
    const isDate = this.radioTargets.some((radio) => radio.checked && radio.value === "date")

    this.dateFieldTargets.forEach((field) => {
      field.classList.toggle("hidden", !isDate)
      field.querySelectorAll("input").forEach((input) => { input.disabled = !isDate })
    })
  }
}
