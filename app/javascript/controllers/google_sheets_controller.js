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
    // Check if URL already has an api_key parameter
    const url = new URL(this.csvUrlValue, window.location.origin)
    const hasApiKey = url.searchParams.has('api_key')

    if (!hasApiKey) {
      // User needs to add an API key
      const title = "⚠️ API Key Required for Google Sheets"
      const content = `To import data into Google Sheets, you need an API key:

1. Go to Settings → API Keys
2. Create a new API key with "read" permission
3. Copy the API key
4. Add it to this URL as: ?api_key=YOUR_KEY

Example:
${this.csvUrlValue}&api_key=YOUR_API_KEY_HERE

Then use the full URL with =IMPORTDATA() in Google Sheets.`

      this.#showInfoDialog(title, content, false)
      return
    }

    try {
      // Copy the full URL to clipboard
      await navigator.clipboard.writeText(this.csvUrlValue)

      // Show instructions with API key
      const title = "✅ CSV URL Copied!"
      const content = `To import into Google Sheets:

1. Create a new Google Sheet
2. In cell A1, enter: =IMPORTDATA("${this.csvUrlValue}")
3. Press Enter

Note: This URL includes your API key. Keep it secure!`

      this.#showInfoDialog(title, content, true)
    } catch (err) {
      // Fallback if clipboard API fails
      const title = "Copy URL for Google Sheets"
      const content = `Copy this URL and use it with =IMPORTDATA() in Google Sheets:

${this.csvUrlValue}`

      this.#showInfoDialog(title, content, true)
    }
  }

  #showInfoDialog(title, content, shouldOpenGoogleSheets = false) {
    const dialog = document.getElementById('info-dialog')

    if (!dialog) {
      console.warn('Info dialog element not found, falling back to alert')
      alert(`${title}\n\n${content}`)
      // Don't open Google Sheets if dialog failed to load
      return
    }

    // Wait a moment for Stimulus controllers to connect if needed
    if (!dialog.controller) {
      console.warn('Info dialog controller not ready, waiting...')
      setTimeout(() => {
        if (dialog.controller) {
          dialog.controller.show(title, content)
          // Only open Google Sheets if dialog successfully shows
          if (shouldOpenGoogleSheets) {
            window.open('https://sheets.google.com/create', '_blank')
          }
        } else {
          console.error('Info dialog controller failed to connect, falling back to alert')
          alert(`${title}\n\n${content}`)
          // Don't open Google Sheets if dialog failed to load
        }
      }, 100)
      return
    }

    dialog.controller.show(title, content)
    // Only open Google Sheets if dialog successfully shows
    if (shouldOpenGoogleSheets) {
      window.open('https://sheets.google.com/create', '_blank')
    }
  }
}
