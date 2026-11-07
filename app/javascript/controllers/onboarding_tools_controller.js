import { Controller } from "@hotwired/stimulus";

export default class extends Controller {
  static targets = ["picker", "summary", "tool", "empty", "other", "chip"];

  connect() {
    this.updateTools();
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
      selected.length > 0
        ? this.summaryTarget.dataset.selectedCount.replace(
            "%{number}",
            selected.length,
          )
        : this.summaryTarget.dataset.placeholder;
    const values = selected.map((tool) => tool.querySelector("input").value);
    for (const chip of this.chipTargets) {
      chip.hidden = !values.includes(chip.dataset.value);
    }
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
}
