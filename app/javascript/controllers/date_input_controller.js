import { Controller } from "@hotwired/stimulus";

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

    const date = new Date(Date.UTC(year, month - 1, day));

    return this.formatValue.replace(/%[YymdeBb]/g, (token) => {
      switch (token) {
        case "%Y": return String(year).padStart(4, "0");
        case "%y": return String(year).slice(-2);
        case "%m": return String(month).padStart(2, "0");
        case "%d": return String(day).padStart(2, "0");
        case "%e": return String(day).padStart(2, " ");
        // Ruby's strftime month names are English, so match them here.
        case "%b": return date.toLocaleString("en", { month: "short", timeZone: "UTC" });
        case "%B": return date.toLocaleString("en", { month: "long", timeZone: "UTC" });
        default: return token;
      }
    });
  }
}
