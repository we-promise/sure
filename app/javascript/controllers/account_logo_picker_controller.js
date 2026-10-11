import { Controller } from "@hotwired/stimulus";

// Previews the icon chosen in the account form. Nothing is saved until the
// form is submitted: a picked or removed icon travels in a hidden field, an
// upload in the file field.
export default class extends Controller {
  static targets = [
    "preview",
    "image",
    "caption",
    "choice",
    "file",
    "option",
    "fallback",
    "blank",
  ];
  static values = { pending: String, removal: String };

  // The picker reloads the icon block from the server, which shows the saved
  // icon, so an earlier choice starts over; a selected file is kept.
  previewTargetConnected() {
    this.savedImage = [...this.imageTarget.childNodes].map((node) =>
      node.cloneNode(true),
    );
    this.savedCaption = this.captionTarget.textContent;
    this.choiceTarget.value = "";
    this.showFile();
  }

  // The picker searches what the account form holds now, not what was saved.
  search({ currentTarget }) {
    const typed = this.element.closest("form").elements;
    const query = currentTarget.form.elements;

    for (const name of ["institution_domain", "institution_name"]) {
      const field = typed.namedItem(`account[${name}]`);
      const input = query.namedItem(name);
      if (field && input) input.value = field.value;
    }
  }

  choose({ params: { choice, label }, currentTarget }) {
    this.clearFile();

    if (choice) {
      this.choiceTarget.value = choice;
      this.showImage(
        currentTarget.querySelector("img").src,
        `${label} · ${this.pendingValue}`,
      );
    } else {
      this.restore();
    }

    this.highlight(currentTarget);
  }

  // Removing brings back the automatic icon, so that is what the preview shows.
  remove() {
    this.clearFile();
    this.restore();
    this.choiceTarget.value = "remove";
    this.imageTarget.replaceChildren(
      this.fallbackTarget.content.cloneNode(true),
    );
    this.captionTarget.textContent = this.removalValue;
    this.highlight(null);
  }

  showFile() {
    const file = this.hasFileTarget && this.fileTarget.files[0];
    if (!file) return;

    this.choiceTarget.value = "";
    this.showImage(
      URL.createObjectURL(file),
      `${file.name} · ${this.pendingValue}`,
    );
    this.highlight(null);
  }

  // The image comes from the server-rendered blank, so it keeps the shape of
  // every other account logo.
  showImage(src, caption) {
    const image = this.blankTarget.content.querySelector("img").cloneNode();
    image.src = src;
    this.imageTarget.replaceChildren(image);
    this.captionTarget.textContent = caption;
  }

  restore() {
    this.choiceTarget.value = "";
    this.imageTarget.replaceChildren(
      ...this.savedImage.map((node) => node.cloneNode(true)),
    );
    this.captionTarget.textContent = this.savedCaption;
  }

  clearFile() {
    if (this.hasFileTarget) this.fileTarget.value = "";
  }

  highlight(selected) {
    for (const option of this.optionTargets) {
      const active = option === selected;
      option.classList.toggle("border-primary", active);
      option.classList.toggle("border-secondary", !active);
    }
  }
}
