import { Controller } from "@hotwired/stimulus"

// Connects to data-controller="info-dialog"
// Used to show informational messages to users in a modal dialog
export default class extends Controller {
  static targets = ["title", "content"]

  connect() {
    // Expose controller instance on the element for easy access
    this.element.controller = this
  }

  disconnect() {
    this.element.controller = undefined
  }

  // Show the dialog with a title and content
  // Usage: document.getElementById('info-dialog').controller.show('Title', 'Content here')
  show(title, content) {
    this.titleTarget.textContent = title
    this.contentTarget.textContent = content
    this.element.showModal()
  }

  // Alternative method to show with an object for more flexibility
  // Usage: document.getElementById('info-dialog').controller.showInfo({ title: 'Title', content: 'Content' })
  showInfo(data) {
    const normalizedData = this.#normalizeData(data)
    this.titleTarget.textContent = normalizedData.title || "Information"
    this.contentTarget.textContent = normalizedData.content || ""
    this.element.showModal()
  }

  close() {
    this.element.close()
  }

  #normalizeData(data) {
    if (typeof data === "string") {
      return { title: "Information", content: data }
    }
    return data
  }
}
