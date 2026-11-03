import { Controller } from "@hotwired/stimulus";

// Shows the hint for the option picked in a DS::Select inside the element,
// so it describes the choice before the form is submitted. Each hint target
// names its option in data-value.
export default class extends Controller {
  static targets = ["hint"];

  update(event) {
    const value = event.detail?.value;
    if (value === undefined) return;

    for (const hint of this.hintTargets) {
      hint.hidden = hint.dataset.value !== value;
    }
  }
}
