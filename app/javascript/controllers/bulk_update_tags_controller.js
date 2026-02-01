import { Controller } from "@hotwired/stimulus";

// Connects to data-controller="bulk-update-tags"
export default class extends Controller {
  static targets = ["touched"];

  touch() {
    this.touchedTarget.value = "1";
  }
}

