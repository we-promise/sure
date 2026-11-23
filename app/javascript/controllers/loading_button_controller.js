import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["button"]
  static values = { loadingText: String }

  showLoading() {
    // Don't prevent form submission, just show loading state
    if (this.hasButtonTarget) {
      this.originalContent = this.buttonTarget.innerHTML
      this.buttonTarget.disabled = true
      this.buttonTarget.setAttribute("aria-disabled", "true")
      this.buttonTarget.setAttribute("aria-busy", "true")
      this.buttonTarget.innerHTML = `
        <span class="inline-flex items-center gap-2">
          <span class="animate-spin rounded-full h-4 w-4 border-b-2 border-current" aria-hidden="true"></span>
          <span>${this.loadingTextValue || 'Loading...'}</span>
        </span>
      `
    }
  }

  // The browser's back/forward cache hands a page back as it was left, so
  // after a full-page submit the button would return disabled and spinning.
  // Wire with pageshow@window->loading-button#restoreIfPersisted.
  restoreIfPersisted(event) {
    if (!event.persisted || !this.hasButtonTarget || this.originalContent === undefined) return

    this.buttonTarget.disabled = false
    this.buttonTarget.removeAttribute("aria-disabled")
    this.buttonTarget.removeAttribute("aria-busy")
    this.buttonTarget.innerHTML = this.originalContent
    this.originalContent = undefined
  }
}
