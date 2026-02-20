import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["button", "menu"]
  static values = { open: Boolean }

  connect() {
    this.open = false
    this.boundOutsideClick = this.handleOutsideClick.bind(this)
    this.boundKeydown = this.handleKeydown.bind(this)

    document.addEventListener("click", this.boundOutsideClick)
    this.element.addEventListener("keydown", this.boundKeydown)
  }

  disconnect() {
    document.removeEventListener("click", this.boundOutsideClick)
    this.element.removeEventListener("keydown", this.boundKeydown)
  }

  toggle = () => {
    this.open ? this.close() : this.openMenu()
  }

  openMenu() {
    this.open = true
    this.menuTarget.classList.remove("hidden")
    this.focusSearch()
  }

  close() {
    this.open = false
    this.menuTarget.classList.add("hidden")
  }

  select(event) {
    const value = event.currentTarget.dataset.value
    const label = event.currentTarget.textContent.trim()

    this.buttonTarget.textContent = label

    this.element.dispatchEvent(
      new CustomEvent("dropdown:select", {
        detail: { value, label },
        bubbles: true
      })
    )

    this.close()
  }

  focusSearch() {
    const input = this.menuTarget.querySelector('input[type="search"]')
    if (input) input.focus({ preventScroll: true })
  }

  handleOutsideClick(event) {
    if (this.open && !this.element.contains(event.target)) {
      this.close()
    }
  }

  handleKeydown(event) {
    if (!this.open) return

    if (event.key === "Escape") {
      this.close()
      this.buttonTarget.focus()
    }

    if (event.key === "Enter" && event.target.dataset.value) {
      event.preventDefault()
      event.target.click()
    }
  }
}
