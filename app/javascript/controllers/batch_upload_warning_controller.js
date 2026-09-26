import { Controller } from "@hotwired/stimulus";

export default class extends Controller {
  static targets = ["allowLargeUpload", "allowDuplicateUpload"];

  static values = {
    totalThreshold: Number,
    totalMessage: String,
    fileThreshold: Number,
    fileMessage: String,
    maxTotalSize: Number,
    maxTotalSizeMessage: String,
    duplicateCheckUrl: String,
    duplicateMessage: String,
  };

  async upload(event) {
    const input = event.currentTarget;
    const files = Array.from(input.files || []);
    const totalSize = files.reduce((total, file) => total + file.size, 0);
    const hasLargeFile = files.some((file) => file.size > this.fileThresholdValue);
    const exceedsMaxTotalSize = totalSize > this.maxTotalSizeValue;
    const warnings = [];

    if (exceedsMaxTotalSize) {
      window.alert(this.maxTotalSizeMessageValue);
      this.allowLargeUploadTarget.value = "false";
      this.allowDuplicateUploadTarget.value = "false";
      input.value = "";
      return;
    }

    if (hasLargeFile) warnings.push(this.fileMessageValue);
    if (totalSize > this.totalThresholdValue) warnings.push(this.totalMessageValue);

    if (warnings.length > 0 && !window.confirm(warnings.join("\n\n"))) {
      this.allowLargeUploadTarget.value = "false";
      this.allowDuplicateUploadTarget.value = "false";
      input.value = "";
      return;
    }

    this.allowLargeUploadTarget.value = hasLargeFile ? "true" : "false";
    const duplicate = await this.hasDuplicatePdf(files);

    if (duplicate && !window.confirm(this.duplicateMessageValue)) {
      this.allowLargeUploadTarget.value = "false";
      this.allowDuplicateUploadTarget.value = "false";
      input.value = "";
      return;
    }

    this.allowDuplicateUploadTarget.value = duplicate ? "true" : "false";
    this.element.requestSubmit();
  }

  async hasDuplicatePdf(files) {
    const seenHashes = new Set();

    for (const file of files) {
      if (file.type !== "application/pdf" && !file.name.toLowerCase().endsWith(".pdf")) continue;

      let digest;
      try {
        digest = await crypto.subtle.digest("SHA-256", await file.arrayBuffer());
      } catch (_error) {
        // The upload endpoint still checks duplicates if browser hashing is unavailable.
        continue;
      }
      const hash = Array.from(new Uint8Array(digest), (byte) => byte.toString(16).padStart(2, "0")).join("");
      if (seenHashes.has(hash)) return true;
      seenHashes.add(hash);

      try {
        const response = await fetch(`${this.duplicateCheckUrlValue}?content_sha256=${hash}`, {
          headers: { Accept: "application/json" },
        });
        if (response.ok && (await response.json()).duplicate) return true;
      } catch (_error) {
        // The upload endpoint still checks duplicates if the preflight request fails.
      }
    }

    return false;
  }
}
