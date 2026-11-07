import { Controller } from "@hotwired/stimulus";

export default class extends Controller {
  static targets = ["panel"];

  connect() {
    this.selectMode();
  }

  selectMode() {
    const radios = this.element.querySelectorAll(
      'input[name="user[onboarding_ai_mode]"]',
    );
    const selected = Array.from(radios).find((radio) => radio.checked);
    for (const radio of radios) {
      radio.setAttribute("aria-expanded", String(radio.checked));
    }
    for (const panel of this.panelTargets) {
      panel.hidden = panel.dataset.mode !== selected?.value;
      for (const fieldset of panel.querySelectorAll("fieldset")) {
        fieldset.disabled = panel.hidden;
      }
    }
  }
}
