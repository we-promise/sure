import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["fileInput", "submitButton"]

  connect() {
    this.updateSubmitButton()
  }

  fileInputTargetConnected() {
    this.fileInputTarget.addEventListener("change", this.updateSubmitButton.bind(this))
  }

  updateSubmitButton() {
    const hasFiles = this.fileInputTarget.files.length > 0
    this.submitButtonTarget.disabled = !hasFiles

    if (hasFiles) {
      const count = this.fileInputTarget.files.length
      this.submitButtonTarget.textContent = count === 1 ? "Upload 1 file" : `Upload ${count} files`
    } else {
      this.submitButtonTarget.textContent = "Upload"
    }
  }
}
