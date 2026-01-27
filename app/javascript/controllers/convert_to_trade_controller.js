import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["customWrapper", "customField", "tickerSelect", "qtyField", "priceField", "priceWarning", "priceWarningMessage"]
  static values = {
    amountCents: Number,
    currency: String
  }

  toggleCustomTicker(event) {
    const value = event.target.value

    if (value === "__custom__") {
      // Show custom ticker field
      this.customWrapperTarget.classList.remove("hidden")
      this.customFieldTarget.required = true
      this.customFieldTarget.focus()
    } else {
      // Hide custom ticker field
      this.customWrapperTarget.classList.add("hidden")
      this.customFieldTarget.required = false
      this.customFieldTarget.value = ""
    }
  }

  validatePrice() {
    // Get the selected security's market price (in cents)
    const selectedOption = this.tickerSelectTarget.selectedOptions[0]
    if (!selectedOption || selectedOption.value === "" || selectedOption.value === "__custom__") {
      this.hidePriceWarning()
      return
    }

    const marketPriceCents = selectedOption.dataset.priceCents
    const ticker = selectedOption.dataset.ticker

    // If no market price data, can't validate
    if (!marketPriceCents || marketPriceCents === "null") {
      this.hidePriceWarning()
      return
    }

    // Calculate the implied/entered price
    let enteredPriceCents = null
    const qty = Number.parseFloat(this.qtyFieldTarget?.value)
    const enteredPrice = Number.parseFloat(this.priceFieldTarget?.value)

    if (enteredPrice && enteredPrice > 0) {
      // User entered a price directly
      enteredPriceCents = enteredPrice * 100
    } else if (qty && qty > 0 && this.amountCentsValue > 0) {
      // Calculate price from amount / qty
      enteredPriceCents = this.amountCentsValue / qty
    }

    if (!enteredPriceCents || enteredPriceCents <= 0) {
      this.hidePriceWarning()
      return
    }

    // Compare prices - warn if they differ by more than 50%
    const marketPrice = Number.parseFloat(marketPriceCents)
    const ratio = enteredPriceCents / marketPrice

    if (ratio < 0.5 || ratio > 2.0) {
      this.showPriceWarning(ticker, enteredPriceCents, marketPrice)
    } else {
      this.hidePriceWarning()
    }
  }

  showPriceWarning(ticker, enteredPriceCents, marketPriceCents) {
    if (!this.hasPriceWarningTarget) return

    const enteredPrice = this.formatMoney(enteredPriceCents)
    const marketPrice = this.formatMoney(marketPriceCents)

    // Build warning message
    const message = `Your price (${enteredPrice}/share) differs significantly from ${ticker}'s current market price (${marketPrice}). If this seems wrong, you may have selected the wrong security — try using "Enter custom ticker" to specify the correct one.`

    this.priceWarningMessageTarget.textContent = message
    this.priceWarningTarget.classList.remove("hidden")
  }

  hidePriceWarning() {
    if (!this.hasPriceWarningTarget) return
    this.priceWarningTarget.classList.add("hidden")
  }

  formatMoney(cents) {
    const dollars = cents / 100
    return new Intl.NumberFormat('en-US', {
      style: 'currency',
      currency: this.currencyValue || 'USD'
    }).format(dollars)
  }
}
