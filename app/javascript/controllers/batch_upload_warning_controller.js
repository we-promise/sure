import { Controller } from "@hotwired/stimulus";

export default class extends Controller {
  static targets = ["allowLargeUpload"];

  static values = {
    totalThreshold: Number,
    totalMessage: String,
    fileThreshold: Number,
    fileMessage: String,
    maxTotalSize: Number,
    maxTotalSizeMessage: String,
  };

  upload(event) {
    const input = event.currentTarget;
    const files = Array.from(input.files || []);
    const totalSize = files.reduce((total, file) => total + file.size, 0);
    const hasLargeFile = files.some((file) => file.size > this.fileThresholdValue);
    const exceedsMaxTotalSize = totalSize > this.maxTotalSizeValue;
    const warnings = [];

    if (exceedsMaxTotalSize) {
      window.alert(this.maxTotalSizeMessageValue);
      this.allowLargeUploadTarget.value = "false";
      input.value = "";
      return;
    }

    if (hasLargeFile) warnings.push(this.fileMessageValue);
    if (totalSize > this.totalThresholdValue) warnings.push(this.totalMessageValue);

    if (warnings.length > 0 && !window.confirm(warnings.join("\n\n"))) {
      this.allowLargeUploadTarget.value = "false";
      input.value = "";
      return;
    }

    this.allowLargeUploadTarget.value = hasLargeFile ? "true" : "false";
    this.element.requestSubmit();
  }
}
