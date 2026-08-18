import { Controller } from "@hotwired/stimulus";

export default class extends Controller {
  static targets = ["input", "fileName", "uploadArea", "uploadText"];

  connect() {
    this._fileSelected = this.fileSelected.bind(this);
    this._formSubmitting = this.formSubmitting.bind(this);

    if (this.hasInputTarget) {
      this.inputTarget.addEventListener("change", this._fileSelected);
    }

    // Find the form element
    this.form = this.element.closest("form");
    if (this.form) {
      this.form.addEventListener("turbo:submit-start", this._formSubmitting);
    }
  }

  disconnect() {
    if (this.hasInputTarget) {
      this.inputTarget.removeEventListener("change", this._fileSelected);
    }

    if (this.form) {
      this.form.removeEventListener("turbo:submit-start", this._formSubmitting);
    }
  }

  triggerFileInput() {
    if (this.hasInputTarget) {
      this.inputTarget.click();
    }
  }

  fileSelected() {
    if (this.hasInputTarget && this.inputTarget.files.length > 0) {
      const fileName = this.inputTarget.files[0].name;

      if (this.hasFileNameTarget) {
        // Find the paragraph element inside the fileName target
        const fileNameText = this.fileNameTarget.querySelector("p");
        if (fileNameText) {
          fileNameText.textContent = fileName;
        }

        this.fileNameTarget.classList.remove("hidden");
      }

      if (this.hasUploadTextTarget) {
        this.uploadTextTarget.classList.add("hidden");
      }
    }
  }

  formSubmitting() {
    if (
      this.hasFileNameTarget &&
      this.hasInputTarget &&
      this.inputTarget.files.length > 0
    ) {
      const fileNameText = this.fileNameTarget.querySelector("p");
      if (fileNameText) {
        fileNameText.textContent = `Uploading ${this.inputTarget.files[0].name}...`;
      }

      // Change the icon to a loader
      const iconContainer =
        this.fileNameTarget.querySelector(".lucide-file-text");
      if (iconContainer) {
        iconContainer.classList.add("animate-pulse");
      }
    }

    if (this.hasUploadAreaTarget) {
      this.uploadAreaTarget.classList.add("opacity-70");
    }
  }
}
