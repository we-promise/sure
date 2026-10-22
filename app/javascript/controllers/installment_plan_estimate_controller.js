import { Controller } from "@hotwired/stimulus"

// Asks the server for the schedule the current form would create. The server
// runs the loan engine, so the dialog never grows a second copy of the EMI
// formula.
export default class extends Controller {
  static targets = ["estimate"]
  static values = { url: String }

  disconnect() {
    clearTimeout(this.timeout)
    this.abortController?.abort()
  }

  update() {
    clearTimeout(this.timeout)
    this.timeout = setTimeout(() => this.refresh(), 250)
  }

  async refresh() {
    const params = new URLSearchParams(new FormData(this.element))

    this.abortController?.abort()
    this.abortController = new AbortController()

    try {
      const response = await fetch(`${this.urlValue}?${params}`, {
        headers: { Accept: "text/html" },
        signal: this.abortController.signal
      })
      if (!response.ok) return

      this.estimateTarget.innerHTML = await response.text()
    } catch (error) {
      if (error.name !== "AbortError") console.error(error)
    }
  }
}
