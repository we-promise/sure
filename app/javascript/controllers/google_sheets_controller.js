import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static values = {
    csvUrl: String
  }

  connect() {
    // When the link is clicked, copy the CSV URL and show instructions
    this.element.addEventListener('click', (e) => {
      e.preventDefault()
      this.copyAndShowInstructions()
    })
  }

  async copyAndShowInstructions() {
    try {
      // Copy the full URL to clipboard
      await navigator.clipboard.writeText(this.csvUrlValue)

      // Show instructions
      alert(`CSV URL copied to clipboard!\n\nTo import into Google Sheets:\n1. Create a new Google Sheet\n2. In cell A1, enter: =IMPORTDATA("${this.csvUrlValue}")\n3. Press Enter\n\nNote: You may need to be logged in to access the data.`)

      // Open Google Sheets in a new tab
      window.open('https://sheets.google.com/create', '_blank')
    } catch (err) {
      // Fallback if clipboard API fails
      alert(`Copy this URL and use it with =IMPORTDATA() in Google Sheets:\n\n${this.csvUrlValue}`)
      window.open('https://sheets.google.com/create', '_blank')
    }
  }
}
