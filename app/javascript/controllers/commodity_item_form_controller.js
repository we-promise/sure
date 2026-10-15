import { Controller } from "@hotwired/stimulus";

// Commodity item form: prefills the default fineness for the chosen form and
// the metal price from the stored spot price for the purchase date. Values the
// user typed are never overwritten.
export default class extends Controller {
  static targets = [
    "form",
    "quantity",
    "weight",
    "unit",
    "fineness",
    "date",
    "currency",
    "price",
    "priceBasis",
    "spotHint",
  ];
  static values = {
    lookupUrl: String,
    code: String,
    finenessDefaults: Object,
    gramsPerOzt: String,
  };

  connect() {
    this.finenessDirty = false;
    this.priceDirty = this.priceTarget.value !== "";
    this.lookupPrice();
  }

  formChanged() {
    const fineness = this.finenessDefaultsValue[this.formTarget.value];
    if (!this.finenessDirty && fineness) this.finenessTarget.value = fineness;
    this.refreshPrice();
  }

  finenessEdited() {
    this.finenessDirty = true;
  }

  priceEdited() {
    this.priceDirty = this.priceTarget.value !== "";
  }

  async lookupPrice() {
    if (!this.dateTarget.value) return;

    const params = new URLSearchParams({
      code: this.codeValue,
      date: this.dateTarget.value,
      currency: this.currencyTarget.value,
    });

    try {
      const response = await fetch(`${this.lookupUrlValue}?${params}`, {
        headers: { Accept: "application/json" },
      });
      if (!response.ok) return;

      this.spot = await response.json();
      this.showHint();
      this.refreshPrice();
    } catch {
      // Prefill is a convenience; the user can always type the price.
    }
  }

  refreshPrice() {
    if (!this.spot?.price_per_ozt || this.priceDirty) return;

    const perOzt = Number(this.spot.price_per_ozt);
    let value;
    switch (this.priceBasisTarget.value) {
      case "per_ozt":
        value = perOzt.toFixed(4);
        break;
      case "per_g":
        value = Number(this.spot.price_per_g).toFixed(4);
        break;
      default: {
        const fineOzt = this.fineTroyOunces();
        if (!fineOzt) return;
        value = (perOzt * fineOzt).toFixed(2);
      }
    }
    this.priceTarget.value = value;
  }

  showHint() {
    if (!this.hasSpotHintTarget) return;
    if (!this.spot?.price_per_ozt) {
      this.spotHintTarget.textContent = "";
      return;
    }

    const hint = this.spotHintTarget;
    const label =
      this.spot.source === "yahoo_futures"
        ? hint.dataset.futuresLabel
        : hint.dataset.spotLabel;
    hint.textContent = `${label}: ${Number(this.spot.price_per_ozt).toFixed(2)} ${this.spot.currency} / oz t`;
  }

  fineTroyOunces() {
    const weight = Number(this.weightTarget.value);
    const fineness = Number(this.finenessTarget.value);
    const quantity = Number(this.quantityTarget.value || 1);
    if (!weight || !fineness) return null;

    const gramsPerOzt = Number(this.gramsPerOztValue);
    const grams =
      this.unitTarget.value === "ozt" ? weight * gramsPerOzt : weight;
    return (grams * fineness * quantity) / gramsPerOzt;
  }
}
