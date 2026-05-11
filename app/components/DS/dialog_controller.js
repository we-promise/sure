import { Controller } from "@hotwired/stimulus";

// Connects to data-controller="dialog"
export default class extends Controller {
  static targets = ["content"]

  static values = {
    autoOpen: { type: Boolean, default: false },
    reloadOnClose: { type: Boolean, default: false },
    disableClickOutside: { type: Boolean, default: false },
  };

  connect() {
    if (this.element.open) return;
    if (this.autoOpenValue) {
      this.element.showModal();
    }
  }
  
  // If the user clicks anywhere outside of the visible content, close the dialog
  clickOutside(e) {
    if (this.disableClickOutsideValue) return;
    if (!this.contentTarget.contains(e.target)) {
      this.close();
    }
  }

  close() {
    this.element.close();
    this.#clearParentModalFrame();

    if (this.reloadOnCloseValue) {
      Turbo.visit(window.location.href);
    }
  }

  // When the dialog lives inside a top-level <turbo-frame id="modal">,
  // emptying the frame on close stops Turbo's page cache from snapshotting
  // an open dialog and reopening it on browser back.
  #clearParentModalFrame() {
    const frame = this.element.closest('turbo-frame[id="modal"]');
    if (frame) frame.innerHTML = "";
  }
}
