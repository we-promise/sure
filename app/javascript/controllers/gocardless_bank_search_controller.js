import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["results"]
  static values  = { country: { type: String, default: "gb" } }

  connect() {
    this.searchTimeout = null
  }

  disconnect() {
    clearTimeout(this.searchTimeout)
  }

  updateCountry(event) {
    this.countryValue = event.target.value
    this.resultsTarget.innerHTML = ""
  }

  search(event) {
    clearTimeout(this.searchTimeout)
    const query = event.target.value.trim()

    if (query.length < 2) {
      this.resultsTarget.innerHTML = ""
      return
    }

    this.searchTimeout = setTimeout(() => {
      this.fetchBanks(query)
    }, 300)
  }

  async fetchBanks(query) {
    this.resultsTarget.innerHTML = `
      <p class="text-xs text-secondary px-1">Searching...</p>
    `

    try {
      const response = await fetch(
        `/gocardless_items/search_banks?q=${encodeURIComponent(query)}&country=${encodeURIComponent(this.countryValue)}`,
        { headers: { "Accept": "application/json" } }
      )

      if (!response.ok) {
        throw new Error(`Server error: ${response.status}`)
      }

      const banks = await response.json()

      if (!Array.isArray(banks) || banks.length === 0) {
        this.resultsTarget.innerHTML = `
          <p class="text-xs text-secondary px-1">No banks found — try a different search term.</p>
        `
        return
      }

      this.resultsTarget.innerHTML = banks.map(bank => `
        <form method="post"
              action="/gocardless_items"
              data-turbo="false">
          <input type="hidden" name="authenticity_token" value="${this.csrfToken()}">
          <input type="hidden" name="institution_id" value="${this.escape(bank.id)}">
          <input type="hidden" name="institution_name" value="${this.escape(bank.name)}">
          <button type="submit"
                  class="w-full flex items-center gap-3 p-3 rounded-lg border border-primary hover:bg-container transition-colors text-left cursor-pointer">
            ${bank.logo
              ? `<img src="${this.escape(bank.logo)}" alt="" width="24" height="24" class="rounded">`
              : `<div class="w-6 h-6 rounded bg-secondary flex-shrink-0"></div>`
            }
            <span class="text-sm text-primary">${this.escape(bank.name)}</span>
          </button>
        </form>
      `).join("")

    } catch (e) {
      this.resultsTarget.innerHTML = `
        <p class="text-xs text-destructive px-1">Error loading banks — are your GoCardless credentials configured?</p>
      `
    }
  }

  escape(str) {
    return String(str)
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;")
  }

  csrfToken() {
    return document.querySelector("meta[name='csrf-token']")?.content || ""
  }
}