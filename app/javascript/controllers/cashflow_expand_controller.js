import { Controller } from "@hotwired/stimulus";

export default class extends Controller {
  open() {
    const dialog = this.element.querySelector("dialog");
    if (!dialog) return;

    if (typeof this.originalDraggable === "undefined") {
      this.originalDraggable = this.element.getAttribute("draggable");
    }
    this.element.setAttribute("draggable", "false");

    dialog.showModal();
  }

  restore() {
    if (this.originalDraggable === undefined) return;
    this.originalDraggable
      ? this.element.setAttribute("draggable", this.originalDraggable)
      : this.element.removeAttribute("draggable");
    this.originalDraggable = undefined;
  }
}
