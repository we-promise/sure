import { Controller } from "@hotwired/stimulus";

export default class extends Controller {
  staticTargets = [
    "input",
    "segment",
    "sizeError",
    "fileInput",
    "fileInfo",
    "fileName",
    "fileSize",
  ];
  staticValues = { maxSize: Number };

  select(event) {
    this.#setSource(event.params.source);
  }

  // DS::Button cannot natively trigger a file input (it renders a real
  // <button>), so the click is forwarded to the hidden input here.
  pickFile() {
    this.fileInputTarget.click();
  }

  fileSelected(event) {
    const file = event.target.files[0];

    if (file && file.size > this.maxSizeValue) {
      // Drop the selection so the oversized file is never submitted.
      event.target.value = "";
      this.#setSizeErrorVisible(true);
      this.#setFileInfoVisible(false);
      return;
    }

    this.#setSizeErrorVisible(false);
    // Uploading a custom file is a manual source selection.
    this.#setSource("manual");

    if (file) {
      this.#updateFileInfo(file);
    } else {
      this.#setFileInfoVisible(false);
    }
  }

  #setSource(source) {
    this.inputTarget.value = source;

    this.segmentTargets.forEach((segment) => {
      const isActive = segment.dataset.logoSourceSourceParam === source;
      // Selected styling is encapsulated in the DS::SegmentedControl active
      // class; keep assistive tech in sync with the visual selection.
      segment.classList.toggle("segmented-control__segment--active", isActive);
      segment.setAttribute("aria-pressed", String(isActive));
    });
  }

  #setSizeErrorVisible(visible) {
    if (!this.hasSizeErrorTarget) return;

    this.sizeErrorTarget.classList.toggle("hidden", !visible);
  }

  #updateFileInfo(file) {
    const humanReadable = (bytes) => {
      if (bytes < 1024) return `${bytes} B`;
      if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`;
      return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
    };

    const maxHuman = (bytes) => {
      if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(0)} KB`;
      return `${(bytes / (1024 * 1024)).toFixed(0)} MB`;
    };

    this.fileNameTarget.textContent = file.name;
    this.fileSizeTarget.textContent = ` — ${humanReadable(file.size)} of ${maxHuman(this.maxSizeValue)}`;
    this.#setFileInfoVisible(true);
  }

  #setFileInfoVisible(visible) {
    if (!this.hasFileInfoTarget) return;

    this.fileInfoTarget.classList.toggle("hidden", !visible);
  }
}
