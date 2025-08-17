import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["button"]
  static values = { loadingText: String }

  showLoading() {
    // Don't prevent form submission, just show loading state
    if (this.hasButtonTarget) {
      this.buttonTarget.disabled = true
      this.buttonTarget.innerHTML = `
        <div class="flex items-center gap-2">
          <div class="animate-spin rounded-full h-4 w-4 border-b-2 border-current"></div>
          ${this.loadingTextValue || 'Loading...'}
        </div>
      `
    }
  }
}