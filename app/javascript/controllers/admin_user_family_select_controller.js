import { Controller } from "@hotwired/stimulus";

export default class extends Controller {
  static targets = ["select", "newFamilyFields", "nameInput"];

  connect() {
    this.toggle();
  }

  toggle() {
    if (this.hasSelectTarget && this.hasNewFamilyFieldsTarget) {
      const isNew = this.selectTarget.value === "new";
      this.newFamilyFieldsTarget.classList.toggle("hidden", !isNew);
      if (isNew && this.hasNameInputTarget) {
        this.nameInputTarget.focus();
      }
    }
  }
}
