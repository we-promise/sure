import { Controller } from "@hotwired/stimulus";

export default class extends Controller {
  connect() {
    this.element.addEventListener('mousedown', (e) => {
      e.preventDefault();
      const option = e.target;
      if (option.tagName === 'OPTION') {
        option.selected = !option.selected;
        const event = new Event('change', { bubbles: true });
        this.element.dispatchEvent(event);
      }
    });
  }
}