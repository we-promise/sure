import { Controller } from "@hotwired/stimulus"

// Live "what-if": debounce input changes and POST the current plan inputs
// to the forecast endpoint, which streams back the recomputed KPI cards
// without persisting. Saving is a separate form submit (#update).
export default class extends Controller {
  static targets = ["form"]
  static values = { url: String, debounce: { type: Number, default: 300 } }

  preview() {
    clearTimeout(this.timer)
    this.timer = setTimeout(() => this.fetchPreview(), this.debounceValue)
  }

  async fetchPreview() {
    const response = await fetch(this.urlValue, {
      method: "PATCH",
      body: new FormData(this.formTarget),
      headers: {
        Accept: "text/vnd.turbo-stream.html",
        "X-CSRF-Token": document.querySelector("meta[name='csrf-token']")?.content
      }
    })

    if (response.ok) {
      window.Turbo.renderStreamMessage(await response.text())
    }
  }

  disconnect() {
    clearTimeout(this.timer)
  }
}
