import { Controller } from "@hotwired/stimulus";

export default class extends Controller {
  static targets = ["kind", "hdFields"];

  connect() {
    this.toggle();
  }

  toggle() {
    const visible = this.kindTarget.value === "bip84";
    this.hdFieldsTarget.hidden = !visible;
    for (const input of this.hdFieldsTarget.querySelectorAll("input")) {
      input.disabled = !visible;
    }
  }
}
