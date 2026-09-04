import { Controller } from "@hotwired/stimulus";

export default class extends Controller {
  static targets = [
    "input",
    "segment",
    "sizeError",
    "fileInput",
    "fileInfo",
    "fileName",
    "fileSize",
    "preview",
  ];
  static values = { maxSize: Number };

  #previewUrl = null;

  select(event) {
    this.#setSource(event.params.source);
  }

  // DS::Button cannot natively trigger a file input (it renders a real
  // <button>), so the click is forwarded to the hidden input here.
  pickFile() {
    this.fileInputTarget.click();
  }

  disconnect() {
    this.#revokePreviewUrl();
  }

  fileSelected(event) {
    const file = event.target.files[0];

    if (file && file.size > this.maxSizeValue) {
      // Drop the selection so the oversized file is never submitted.
      event.target.value = "";
      this.#setSizeErrorVisible(true);
      this.#setFileInfoVisible(false);
      this.#hidePreview();
      return;
    }

    this.#setSizeErrorVisible(false);
    // Uploading a custom file is a manual source selection.
    this.#setSource("manual");

    if (file) {
      this.#updateFileInfo(file);
      this.#showPreview(file);
    } else {
      this.#setFileInfoVisible(false);
      this.#hidePreview();
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

  // Shows a local preview of the chosen picture so the user can confirm the
  // image before submitting (previously there was no preview at all). If the
  // browser cannot decode the file the preview simply stays hidden — the
  // upload itself is still allowed, since the server decides what to accept.
  #showPreview(file) {
    if (!this.hasPreviewTarget) return;

    this.#revokePreviewUrl();
    this.#previewUrl = URL.createObjectURL(file);
    this.previewTarget.src = this.#previewUrl;
    this.previewTarget.classList.remove("hidden");
  }

  #hidePreview() {
    if (!this.hasPreviewTarget) return;

    this.#revokePreviewUrl();
    this.previewTarget.src = "";
    this.previewTarget.classList.add("hidden");
  }

  #revokePreviewUrl() {
    if (this.#previewUrl) {
      URL.revokeObjectURL(this.#previewUrl);
      this.#previewUrl = null;
    }
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

    // Browsers expose only the filename (never the full path) for security;
    // abbreviate long names so the info line stays on one row.
    const MAX_NAME_LEN = 24;
    const displayName =
      file.name.length > MAX_NAME_LEN
        ? `${file.name.slice(0, MAX_NAME_LEN - 3)}…${file.name.slice(-3)}`
        : file.name;

    this.fileNameTarget.textContent = displayName;
    this.fileNameTarget.title = file.name;
    this.fileSizeTarget.textContent = ` · ${humanReadable(file.size)} / ${maxHuman(this.maxSizeValue)}`;
    this.#setFileInfoVisible(true);
  }

  #setFileInfoVisible(visible) {
    if (!this.hasFileInfoTarget) return;

    this.fileInfoTarget.classList.toggle("hidden", !visible);
  }
}
