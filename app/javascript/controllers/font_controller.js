import { Controller } from "@hotwired/stimulus";

export default class extends Controller {
  static values = { userPreference: String };

  connect() {
    this.applyFont();
  }

  // Called automatically when server-updated value changes
  userPreferenceValueChanged() {
    this.applyFont();
  }

  // Called from the select change event so the UI updates instantly
  updateFont(event) {
    const font = event.currentTarget.value;
    this.setFont(font);
  }

  applyFont() {
    const font = this.userPreferenceValue || "sans";
    this.setFont(font);
  }

  setFont(font) {
    // remove any known font-* classes then add the selected one
    document.documentElement.classList.remove("font-sans", "font-display", "font-mono", "font-noto");

    switch (font) {
      case "display":
        document.documentElement.classList.add("font-display");
        break;
      case "mono":
        document.documentElement.classList.add("font-mono");
        break;
      case "noto":
        document.documentElement.classList.add("font-noto");
        break;
      default:
        document.documentElement.classList.add("font-sans");
    }

    // keep a lightweight client-side hint so immediate navigations keep it until server render
    try {
      localStorage.setItem("preferredFont", font);
    } catch (e) {
      /* noop */
    }
  }
}
