import { Controller } from "@hotwired/stimulus";

// Points the "add vest" form at the grant picked in its select.
export default class extends Controller {
  changeGrant(event) {
    this.element.action = event.target.value;
  }
}
