import { Controller } from "@hotwired/stimulus"

export default class AttachmentUploadController extends Controller {
  static targets = ["fileInput", "submitButton", "fileName", "uploadText"]
  static values = {
    maxFiles: Number,
    maxSize: Number,
    locale: String,
    labels: Object
  }

  connect() {
    this.updateSubmitButton()
  }

  triggerFileInput() {
    this.fileInputTarget.click()
  }

  updateSubmitButton() {
    const files = Array.from(this.fileInputTarget.files)
    const hasFiles = files.length > 0

    // Basic validation hints (server validates definitively)
    let isValid = hasFiles
    let errorMessage = ""

    if (hasFiles) {
      if (this.hasUploadTextTarget) this.uploadTextTarget.classList.add("hidden")
      if (this.hasFileNameTarget) {
        const filenames = files.map(f => f.name).join(", ")
        const textElement = this.fileNameTarget.querySelector("p")
        if (textElement) textElement.textContent = filenames
        this.fileNameTarget.classList.remove("hidden")
      }

      // Check file count
      if (files.length > this.maxFilesValue) {
        isValid = false
        errorMessage = this.labelsValue.too_many_files
      }

      // Check file sizes
      const oversizedFiles = files.filter(file => file.size > this.maxSizeValue)
      if (oversizedFiles.length > 0) {
        isValid = false
        errorMessage = this.labelsValue.file_too_large
      }
    } else {
      if (this.hasUploadTextTarget) this.uploadTextTarget.classList.remove("hidden")
      if (this.hasFileNameTarget) this.fileNameTarget.classList.add("hidden")
    }

    this.submitButtonTarget.disabled = !isValid

    if (hasFiles && isValid) {
      const count = files.length
      const pluralCategory = new Intl.PluralRules(this.localeValue).select(count)
      const template = this.labelsValue.upload_files[pluralCategory] || this.labelsValue.upload_files.other
      this.submitButtonTarget.textContent = template.replace("%{count}", count)
    } else if (errorMessage) {
      this.submitButtonTarget.textContent = errorMessage
    } else {
      this.submitButtonTarget.textContent = this.labelsValue.upload
    }
  }
}
