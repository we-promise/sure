import { Controller } from "@hotwired/stimulus";

// Toggles between selecting an existing merchant and entering a new one
export default class extends Controller {
  static targets = ["selectMode", "newMode", "merchantSelect", "merchantName"];

  showNew() {
    this.selectModeTarget.classList.add("hidden");
    this.newModeTarget.classList.remove("hidden");
    this.merchantSelectTarget.value = "";
    this.merchantNameTarget.focus();
  }

  showSelect() {
    this.newModeTarget.classList.add("hidden");
    this.selectModeTarget.classList.remove("hidden");
    this.merchantNameTarget.value = "";
  }
}
