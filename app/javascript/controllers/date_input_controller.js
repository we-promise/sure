import { Controller } from "@hotwired/stimulus";
import { utcFormat } from "d3-time-format";

// A native date input always renders in the browser's locale. Mirror its ISO
// value into a sibling span using the family's format; the span covers the
// native text until the input is focused.
export default class extends Controller {
  static targets = ["input", "display"];
  static values = { format: String };

  connect() {
    this.render();
  }

  render() {
    const value = this.inputTarget.value;
    this.displayTarget.textContent = value ? this.#format(value) : "";
  }

  #format(iso) {
    const [year, month, day] = iso.split("-").map(Number);
    if (!year || !month || !day) return "";

    return utcFormat(this.formatValue)(new Date(Date.UTC(year, month - 1, day)));
  }
}
