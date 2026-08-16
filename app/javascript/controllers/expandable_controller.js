import { Controller } from "@hotwired/stimulus";

// Connects to data-controller="expandable"
//
// Surfaces a cramped region (a chart card, a dense table row) in a roomier
// modal, mirroring the dashboard cashflow expand button. The trigger lives
// outside the <dialog>, so it is out of scope for the DS--dialog controller's
// own actions — this thin wrapper bridges the two.
//
// Native <dialog> tracks the previously focused element across showModal() /
// close(), so focus returns to the expand button on its own.
export default class extends Controller {
  static targets = ["dialog"];

  open() {
    const dialog = this.hasDialogTarget
      ? this.dialogTarget
      : this.element.querySelector("dialog");

    if (!dialog || dialog.open) return;

    dialog.showModal();
  }
}
