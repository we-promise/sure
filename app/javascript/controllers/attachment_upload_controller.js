import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["fileInput", "submitButton"]
  static values = {
    maxFiles: Number,
    maxSize: Number
  }

  connect() {
    this.updateSubmitButton()
  }

  fileInputTargetConnected() {
    this.fileInputTarget.addEventListener("change", this.updateSubmitButton.bind(this))
  }

  updateSubmitButton() {
    const files = Array.from(this.fileInputTarget.files)
    const hasFiles = files.length > 0

    // Basic validation hints (server validates definitively)
    let isValid = hasFiles
    let errorMessage = ""

    if (hasFiles) {
      // Check file count
      if (files.length > this.maxFilesValue) {
        isValid = false
        errorMessage = `Too many files (max ${this.maxFilesValue})`
      }

      // Check file sizes
      const oversizedFiles = files.filter(file => file.size > this.maxSizeValue)
      if (oversizedFiles.length > 0) {
        isValid = false
        errorMessage = `File too large (max ${Math.round(this.maxSizeValue / 1024 / 1024)}MB)`
      }
    }

    this.submitButtonTarget.disabled = !isValid

    if (hasFiles && isValid) {
      const count = files.length
      this.submitButtonTarget.textContent = count === 1 ? "Upload 1 file" : `Upload ${count} files`
    } else if (errorMessage) {
      this.submitButtonTarget.textContent = errorMessage
    } else {
      this.submitButtonTarget.textContent = "Upload"
    }
  }
}
