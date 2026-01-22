import { Controller } from "@hotwired/stimulus";

export default class extends Controller {
  open() {
    const dialog = this.element.querySelector("dialog");

    // Disable dragging on the section while dialog is open
    this.element.setAttribute("draggable", "false");

    // Re-enable dragging when dialog closes
    dialog?.addEventListener('close', () => {
      this.element.setAttribute("draggable", "true");
    }, { once: true });

    dialog?.showModal();
  }
}
