import { Controller } from "@hotwired/stimulus";

// Shows the frequency-picker field groups relevant to the selected preset.
// Display logic only; the preset-to-rules translation is server-side.
export default class extends Controller {
  static targets = ["preset", "group"];

  connect() {
    this.update();
  }

  update() {
    const preset = this.presetTarget.value;

    this.groupTargets.forEach((group) => {
      const presets = (group.dataset.presets || "").split(",");
      group.classList.toggle("hidden", !presets.includes(preset));
    });
  }
}
