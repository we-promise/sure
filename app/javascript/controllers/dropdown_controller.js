import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["menu", "button"]
  
  toggle() {
    this.menuTarget.classList.toggle("hidden")
  }

  select(event) {
    const value = event.currentTarget.dataset.value
    const label = event.currentTarget.textContent.trim()

    this.buttonTarget.textContent = label

    const input = this.element.querySelector("input[type=hidden]")
    if (input) {
      input.value = value
      input.dispatchEvent(new Event("change", { bubbles: true }))
    }

    this.menuTarget.classList.add("hidden")

    this.element.dispatchEvent(new CustomEvent("dropdown:select", {
      detail: { value: value, label: label },
      bubbles: true
    }))
  }
}
