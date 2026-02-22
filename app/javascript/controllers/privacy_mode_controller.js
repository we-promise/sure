import { Controller } from "@hotwired/stimulus"

// Privacy Mode Controller
// Toggles visibility of financial numbers across the page.
// Elements with class "privacy-sensitive" will be blurred when active.
// State persists in localStorage so it survives page navigations.
export default class extends Controller {
  static targets = ["toggle"]

  connect() {
    this.active = localStorage.getItem("privacyMode") === "true"
    this._apply()
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

    this.toggleTargets.forEach((el) => {
      el.setAttribute("aria-pressed", this.active.toString())
    })
  }
}