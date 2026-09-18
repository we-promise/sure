import { Controller } from "@hotwired/stimulus";

// The preset that reveals the unit picker; mirrors FrequencyPreset::INTERVAL.
const INTERVAL_PRESET = "interval";

// Shows the frequency-picker field groups relevant to the selected preset.
// Under the custom interval preset, groups listing the chosen unit in
// data-units show as well. Display logic only; the preset-to-rules
// translation is server-side.
export default class extends Controller {
  static targets = ["preset", "unit", "group"];

  connect() {
    this.update();
  }

  update() {
    const preset = this.presetTarget.value;
    const unit =
      preset === INTERVAL_PRESET && this.hasUnitTarget
        ? this.unitTarget.value
        : null;

    this.groupTargets.forEach((group) => {
      const presets = (group.dataset.presets || "").split(",");
      const units = (group.dataset.units || "").split(",");
      const visible =
        presets.includes(preset) || (unit !== null && units.includes(unit));

      group.classList.toggle("hidden", !visible);
    });
  }
}
