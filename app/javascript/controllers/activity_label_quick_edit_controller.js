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

    this.dropdownTarget.classList.toggle("hidden")
  }

  closeOnClickOutside(event) {
    if (!this.element.contains(event.target)) {
      this.close()
    }
  }

  close() {
    if (this.hasDropdownTarget) {
      this.dropdownTarget.classList.add("hidden")
    }
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
    try {
      const response = await fetch(this.urlValue, {
        method: "PATCH",
        headers: {
          "Content-Type": "application/json",
          "X-CSRF-Token": document.querySelector('meta[name="csrf-token"]').content,
          "Accept": "text/vnd.turbo-stream.html, application/json"
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
        // Reload the page to show updated badge
        window.location.reload()
      } else {
        console.error("Failed to update activity label:", response.status)
      }
    } catch (error) {
      console.error("Error updating activity label:", error)
    }
  }
}
