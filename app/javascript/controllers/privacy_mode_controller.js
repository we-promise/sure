import { Controller } from "@hotwired/stimulus"

// Privacy Mode Controller
// Toggles visibility of financial numbers across the page.
// Elements with class "privacy-sensitive" will be blurred when active.
// State persists in localStorage so it survives page navigations.
// A synchronous inline script in <head> pre-applies the class to prevent
// a flash of unblurred content on first paint (see _privacy_mode_check.html.erb).
//
// numbersOnly is the user's Appearance preference for charts: with it on,
// chart shapes stay visible and only the amounts inside them blur (see
// privacy-mode.css). The layout renders it on <html> for first paint, but
// Turbo leaves <html> alone on navigation, so this controller re-applies
// it on every page.
export default class extends Controller {
  static targets = ["toggle", "iconOn", "iconOff"]
  static values = { numbersOnly: Boolean }

  connect() {
    this.active = localStorage.getItem("privacyMode") === "true"
    this._apply()
  }

  // Stimulus also calls this with the initial value, before connect().
  numbersOnlyValueChanged() {
    this._applyNumbersOnly()
  }

  _applyNumbersOnly() {
    document.documentElement.classList.toggle("privacy-numbers-only", this.numbersOnlyValue)
  }

  toggle() {
    this.active = !this.active
    localStorage.setItem("privacyMode", this.active.toString())
    this._apply()
  }

  _apply() {
    if (this.active) {
      document.documentElement.classList.add("privacy-mode")
    } else {
      document.documentElement.classList.remove("privacy-mode")
    }

    // Update button state
    this.toggleTargets.forEach((el) => {
      el.setAttribute("aria-pressed", this.active.toString())
    })

    // Toggle icon visibility: show eye when active (click to reveal), eye-off when inactive
    this.iconOnTargets.forEach((el) => {
      el.classList.toggle("hidden", !this.active)
    })
    this.iconOffTargets.forEach((el) => {
      el.classList.toggle("hidden", this.active)
    })
  }
}