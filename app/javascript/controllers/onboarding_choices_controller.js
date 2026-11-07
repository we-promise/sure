import { Controller } from "@hotwired/stimulus";

export default class extends Controller {
  static targets = ["picker", "summary", "tool", "empty", "other", "panel"];

  connect() {
    this.updateTools();
    this.selectMode();
  }

  selectTool(event) {
    const selected = event.target;
    if (selected.checked) {
      for (const tool of this.toolTargets) {
        const input = tool.querySelector("input");
        if (
          input !== selected &&
          (selected.value === "nothing_yet" || input.value === "nothing_yet")
        ) {
          input.checked = false;
        }
      }
    }
    this.updateTools();
  }

  updateTools() {
    const selected = this.toolTargets.filter(
      (tool) => tool.querySelector("input").checked,
    );
    this.summaryTarget.textContent =
      selected.map((tool) => tool.dataset.label).join(", ") ||
      this.summaryTarget.dataset.placeholder;
    this.otherTarget.hidden = !selected.some(
      (tool) => tool.querySelector("input").value === "other",
    );
    this.otherTarget.querySelector("input").disabled = this.otherTarget.hidden;
  }

  filter(event) {
    const query = event.target.value.trim().toLocaleLowerCase();
    for (const tool of this.toolTargets) {
      tool.hidden = !tool.dataset.label.toLocaleLowerCase().includes(query);
    }
    this.emptyTarget.hidden = this.toolTargets.some((tool) => !tool.hidden);
  }

  closePicker() {
    this.pickerTarget.open = false;
    this.pickerTarget.querySelector("summary").focus();
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
    }
  }
}
