import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["input", "fileName", "uploadArea", "uploadText"]

  connect() {
    if (this.hasInputTarget) {
      this.boundFileSelected = this.fileSelected.bind(this)
      this.inputTarget.addEventListener("change", this.boundFileSelected)
    }
    
    // Find the form element
    this.form = this.element.closest("form")
    if (this.form) {
      this.boundFormSubmitting = this.formSubmitting.bind(this)
      this.form.addEventListener("turbo:submit-start", this.boundFormSubmitting)
    }
  }

  disconnect() {
    if (this.hasInputTarget) {
      this.inputTarget.removeEventListener("change", this.boundFileSelected)
    }
    
    if (this.form) {
      this.form.removeEventListener("turbo:submit-start", this.boundFormSubmitting)
    }
  }

  triggerFileInput() {
    if (this.hasInputTarget) {
      this.inputTarget.click()
    }
  }

  fileSelected() {
    if (this.hasInputTarget && this.inputTarget.files.length > 0) {
      const files = Array.from(this.inputTarget.files)
      const fileName = files.map((file) => file.name).join(", ")
      
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
        const files = Array.from(this.inputTarget.files)
        fileNameText.textContent = `Uploading ${files.map((file) => file.name).join(", ")}...`
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
}
