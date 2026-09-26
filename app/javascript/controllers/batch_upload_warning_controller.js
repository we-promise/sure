import { Controller } from "@hotwired/stimulus";

export default class extends Controller {
  static targets = ["allowLargePdf"];

  static values = {
    threshold: Number,
    message: String,
    pdfThreshold: Number,
    pdfMessage: String,
  };

  upload(event) {
    const input = event.currentTarget;
    const files = Array.from(input.files || []);
    const totalSize = files.reduce((total, file) => total + file.size, 0);
    const hasLargePdf = files.some(
      (file) =>
        (file.type === "application/pdf" || file.name.toLowerCase().endsWith(".pdf")) &&
        file.size > this.pdfThresholdValue,
    );
    const warnings = [];

    if (hasLargePdf) warnings.push(this.pdfMessageValue);
    if (totalSize > this.thresholdValue) warnings.push(this.messageValue);

    if (warnings.length > 0 && !window.confirm(warnings.join("\n\n"))) {
      this.allowLargePdfTarget.value = "false";
      input.value = "";
      return;
    }

    this.allowLargePdfTarget.value = hasLargePdf ? "true" : "false";
    this.element.requestSubmit();
  }
}
