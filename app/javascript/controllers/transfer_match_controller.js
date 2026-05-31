import { Controller } from "@hotwired/stimulus";

// Connects to data-controller="transfer-match"
export default class extends Controller {
  static targets = ["newSelect", "existingSelect"];

  connect() {
    this.updateView(this.element.querySelector("select").value);
  }

  update(event) {
    this.updateView(event.target.value);
  }

  updateView(value) {
    if (value === "new") {
      this.newSelectTarget.classList.remove("hidden");
      this.existingSelectTarget.classList.add("hidden");
    } else {
      this.newSelectTarget.classList.add("hidden");
      this.existingSelectTarget.classList.remove("hidden");
    }
  }
}
