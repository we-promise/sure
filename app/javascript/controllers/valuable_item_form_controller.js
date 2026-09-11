import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["itemType", "material", "weightUnit", "purity"]

  connect() {
    this.update()
  }

  update() {
    const bullion = this.itemTypeTarget.value === "bullion"
    const materials = bullion ? ["gold", "silver", "platinum", "palladium"] : ["diamond", "ruby", "sapphire", "emerald", "other"]
    const units = bullion ? ["gram", "troy_ounce", "kilogram"] : ["carat"]

    this.filterOptions(this.materialTarget, materials)
    this.filterOptions(this.weightUnitTarget, units)
    this.purityTarget.classList.toggle("hidden", !bullion)

    const purityInput = this.purityTarget.querySelector("input")
    purityInput.required = bullion
    if (!bullion) purityInput.value = ""
  }

  filterOptions(select, allowed) {
    Array.from(select.options).forEach((option) => {
      const enabled = allowed.includes(option.value)
      option.disabled = !enabled
      option.hidden = !enabled
    })

    if (!allowed.includes(select.value)) select.value = allowed[0]
  }
}
