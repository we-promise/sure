import { Controller } from "@hotwired/stimulus";

export default class extends Controller {
  static targets = ["input", "image", "fallback", "clearButton", "removeField", "customUrl"];
  static values = {
    fallbackUrl: String,
    uploaded: Boolean,
  };

  disconnect() {
    this.revokePreviewUrl();
  }

  showFileInputPreview(event) {
    const file = event.currentTarget.files[0];
    if (!file) return;

    this.revokePreviewUrl();
    this.previewUrl = URL.createObjectURL(file);
    this.imageTarget.src = this.previewUrl;
    this.imageTarget.classList.remove("hidden");
    this.fallbackTarget.classList.add("hidden");
    this.clearButtonTarget.classList.remove("hidden");
    this.removeFieldTarget.value = "0";
  }

  previewCustomUrl(event) {
    if (this.inputTarget.files.length > 0) return;

    const url = event.currentTarget.value.trim() || this.fallbackUrlValue;
    if (url) {
      this.imageTarget.src = url;
      this.imageTarget.classList.remove("hidden");
      this.fallbackTarget.classList.add("hidden");
    } else if (this.fallbackUrlValue) {
      this.imageTarget.src = this.fallbackUrlValue;
      this.imageTarget.classList.remove("hidden");
      this.fallbackTarget.classList.add("hidden");
    } else {
      this.imageTarget.removeAttribute("src");
      this.imageTarget.classList.add("hidden");
      this.fallbackTarget.classList.remove("hidden");
    }
  }

  clearFileInput() {
    this.inputTarget.value = "";
    this.removeFieldTarget.value = this.uploadedValue ? "1" : "0";
    this.revokePreviewUrl();

    const fallbackUrl = this.hasCustomUrlTarget && this.customUrlTarget.value.trim()
      ? this.customUrlTarget.value.trim()
      : this.fallbackUrlValue;

    if (fallbackUrl) {
      this.imageTarget.src = fallbackUrl;
      this.imageTarget.classList.remove("hidden");
      this.fallbackTarget.classList.add("hidden");
    } else {
      this.imageTarget.removeAttribute("src");
      this.imageTarget.classList.add("hidden");
      this.fallbackTarget.classList.remove("hidden");
    }

    this.clearButtonTarget.classList.add("hidden");
  }

  revokePreviewUrl() {
    if (this.previewUrl) URL.revokeObjectURL(this.previewUrl);
    this.previewUrl = null;
  }
}
