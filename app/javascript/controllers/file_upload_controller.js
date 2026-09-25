import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["input", "fileName", "uploadArea", "uploadText", "sameFormatControl"]

  connect() {
    // Find the form element
    this.form = this.element.closest("form")
    if (this.form) {
      this.form.addEventListener("turbo:submit-start", this.formSubmitting.bind(this))
    }
  }

  disconnect() {
    if (this.form) {
      this.form.removeEventListener("turbo:submit-start", this.formSubmitting.bind(this))
    }
  }

  triggerFileInput() {
    if (this.hasInputTarget) {
      this.inputTarget.click()
    }
  }

  fileSelected() {
    if (this.hasSameFormatControlTarget) {
      const multipleFilesSelected = this.inputTarget.files.length > 1
      this.sameFormatControlTarget.classList.toggle("hidden", !multipleFilesSelected)
      this.sameFormatControlTarget.disabled = !multipleFilesSelected
      if (!multipleFilesSelected) {
        this.sameFormatControlTarget.querySelectorAll("input[type='radio']").forEach((radio) => {
          radio.checked = false
        })
      }
    }

    if (this.hasInputTarget && this.inputTarget.files.length > 0) {
      const fileName = this.selectedFilesLabel()
      
      if (this.hasFileNameTarget) {
        // Find the paragraph element inside the fileName target
        const fileNameText = this.fileNameTarget.querySelector('p')
        if (fileNameText) {
          fileNameText.textContent = fileName
        }
        
        this.fileNameTarget.classList.remove("hidden")
      }
      
      if (this.hasUploadTextTarget) {
        this.uploadTextTarget.classList.add("hidden")
      }
      
    
    }
  }
  
  formSubmitting() {
    if (this.hasFileNameTarget && this.hasInputTarget && this.inputTarget.files.length > 0) {
      const fileNameText = this.fileNameTarget.querySelector('p')
      if (fileNameText) {
        fileNameText.textContent = `Uploading ${this.selectedFilesLabel()}...`
      }
      
      // Change the icon to a loader
      const iconContainer = this.fileNameTarget.querySelector('.lucide-file-text')
      if (iconContainer) {
        iconContainer.classList.add('animate-pulse')
      }
    }
    
    if (this.hasUploadAreaTarget) {
      this.uploadAreaTarget.classList.add("opacity-70")
    }
  }

  selectedFilesLabel() {
    if (this.inputTarget.files.length > 1 && this.inputTarget.dataset.multipleFilesLabel) {
      return this.inputTarget.dataset.multipleFilesLabel.replace("%{count}", this.inputTarget.files.length)
    }

    return this.inputTarget.files[0].name
  }
}
