import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["dropdown", "badge"]
  static values = {
    url: String,
    entryableId: String,
    currentLabel: String
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

    // Just save the label - convert to trade is available separately in detail panel
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
