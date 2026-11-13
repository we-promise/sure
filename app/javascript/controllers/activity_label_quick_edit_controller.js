import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["dropdown", "badge"]
  static values = {
    url: String,
    entryableId: String,
    currentLabel: String,
    entryableType: String,
    convertUrl: String
  }

  connect() {
    // Close dropdown when clicking outside
    this.boundCloseOnClickOutside = this.closeOnClickOutside.bind(this)
    document.addEventListener("click", this.boundCloseOnClickOutside)
  }

  disconnect() {
    document.removeEventListener("click", this.boundCloseOnClickOutside)
  }

  toggle(event) {
    event.preventDefault()
    event.stopPropagation()

    if (this.hasDropdownTarget) {
      this.dropdownTarget.classList.toggle("hidden")
      this.#syncExpanded()
    }
  }

  closeOnClickOutside(event) {
    if (!this.element.contains(event.target)) {
      this.close()
    }
  }

  close() {
    if (this.hasDropdownTarget) {
      this.dropdownTarget.classList.add("hidden")
      this.#syncExpanded()
    }
  }

  // The badge says whether its dropdown is open, for assistive technology,
  // and so a row with it open is not contained (and the dropdown clipped)
  // while a sidebar is dragged.
  #syncExpanded() {
    if (!this.hasBadgeTarget) return
    const open = !this.dropdownTarget.classList.contains("hidden")
    this.badgeTarget.setAttribute("aria-expanded", open.toString())
  }

  async select(event) {
    event.preventDefault()
    event.stopPropagation()

    const label = event.currentTarget.dataset.label

    // Don't update if it's the same label
    if (label === this.currentLabelValue) {
      this.close()
      return
    }

    // For Transactions: Buy/Sell should prompt to convert to trade
    if (this.entryableTypeValue === "Transaction" && (label === "Buy" || label === "Sell") && this.hasConvertUrlValue) {
      this.close()
      // Navigate to convert-to-trade modal in a Turbo frame, passing the selected label
      const url = new URL(this.convertUrlValue, window.location.origin)
      url.searchParams.set("activity_label", label)
      Turbo.visit(url.toString(), { frame: "modal" })
      return
    }

    // For other labels (Dividend, Interest, Fee, etc.) or for Trades, just save the label
    const csrfToken = document.querySelector('meta[name="csrf-token"]')?.content
    if (!csrfToken) {
      console.error("CSRF token not found")
      return
    }

    try {
      const response = await fetch(this.urlValue, {
        method: "PATCH",
        headers: {
          "Content-Type": "application/json",
          "X-CSRF-Token": csrfToken,
          "Accept": "text/vnd.turbo-stream.html"
        },
        body: JSON.stringify({
          entry: {
            entryable_attributes: {
              id: this.entryableIdValue,
              investment_activity_label: label
            }
          }
        })
      })

      if (response.ok) {
        const contentType = response.headers.get("content-type")
        if (contentType?.includes("text/vnd.turbo-stream.html")) {
          // Let Turbo handle the stream response
          const html = await response.text()
          Turbo.renderStreamMessage(html)
        }
        // Update local state and badge
        this.currentLabelValue = label
        this.close()
      } else {
        console.error("Failed to update activity label:", response.status)
      }
    } catch (error) {
      console.error("Error updating activity label:", error)
    }
  }
}
