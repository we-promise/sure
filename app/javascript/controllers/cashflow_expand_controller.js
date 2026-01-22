import { Controller } from "@hotwired/stimulus";

export default class extends Controller {
  open() {
    const dialog = this.element.querySelector("dialog");
    if (!dialog) return;

    // Capture the current draggable state only if it hasn't been captured yet
    if (this.originalDraggable === undefined) {
      this.originalDraggable = this.element.getAttribute("draggable");
    }

    // Disable dragging on the section while dialog is open
    this.element.setAttribute("draggable", "false");

    dialog.showModal();
  }

  restore() {
    if (this.originalDraggable) {
      this.element.setAttribute("draggable", this.originalDraggable);
    } else {
      this.element.removeAttribute("draggable");
    }
    this.originalDraggable = undefined;
  }
}
