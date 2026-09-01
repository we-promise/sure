import { Controller } from "@hotwired/stimulus";

export default class extends Controller {
  static targets = ["radio"];

  select(event) {
    const source = event.params.source;
    this.radioTargets.forEach(radio => {
      if (radio.value === source) {
        radio.checked = true;
      }
    });
  }
}
