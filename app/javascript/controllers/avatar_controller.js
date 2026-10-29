import { Controller } from "@hotwired/stimulus";

export default class extends Controller {
  connect() {
    // An image can finish loading before Stimulus connects (including a cached failure).
    if (this.element.complete) this.update();
  }

  update() {
    this.element.hidden = this.element.naturalWidth === 0;
  }
}
