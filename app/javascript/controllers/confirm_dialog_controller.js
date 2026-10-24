import { Controller } from "@hotwired/stimulus";

// Connects to data-controller="confirm-dialog"
// See javascript/controllers/application.js for how this is wired up
export default class extends Controller {
  static targets = ["title", "subtitle", "confirmButton"];
  static values = { labels: Object };

  handleConfirm(rawData) {
    const data = this.#normalizeRawData(rawData);

    this.#prepareDialog(data);

    this.element.returnValue = "";
    this.element.showModal();

    return new Promise((resolve) => {
      this.element.addEventListener(
        "close",
        () => {
          const isConfirmed = this.element.returnValue === "confirm";
          resolve(isConfirmed);
        },
        { once: true },
      );
    });
  }

  #prepareDialog(data) {
    const variant = data.variant || "primary";

    this.confirmButtonTargets.forEach((button) => {
      if (button.dataset.variant === variant) {
        button.removeAttribute("hidden");
      } else {
        button.setAttribute("hidden", true);
      }

      button.textContent = data.confirmText || this.labelsValue.confirm;
    });

    this.titleTarget.textContent = data.title || this.labelsValue.are_you_sure;
    // Text, never HTML: bodies interpolate record names (merchants, accounts,
    // brokerages, tickers) that come from bank feeds, providers and other
    // family members, however the caller built the confirmation.
    this.subtitleTarget.textContent =
      data.body || this.labelsValue.cannot_be_undone;
  }

  // If data is a string, it's the title.  Otherwise, return the parsed object.
  #normalizeRawData(rawData) {
    try {
      const parsed = JSON.parse(rawData);

      if (typeof parsed === "string") return { title: parsed };
      if (parsed && typeof parsed === "object" && !Array.isArray(parsed)) {
        return parsed;
      }

      // Boolean and empty confirmations use the server-rendered locale defaults.
      return {};
    } catch (e) {
      return { title: rawData };
    }
  }
}
