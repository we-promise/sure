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

    this.scrollToSelected()
    this.focusSearch()
  }

  close() {
    this.open = false
    this.menuTarget.classList.add("hidden")
  }

  select(event) {
    const selectedElement = event.currentTarget
    const value = selectedElement.dataset.value
    const label = selectedElement.dataset.filterName || selectedElement.textContent.trim()

    this.buttonTarget.textContent = label

    const input = this.element.querySelector('input[type="hidden"]')
    if (input) input.value = value

    this.menuTarget
      .querySelectorAll(".filterable-item")
      .forEach(el => {
        el.classList.remove("bg-container-inset")

        const icon = el.querySelector(".check-icon")
        if (icon) icon.classList.add("hidden")
      })

    selectedElement.classList.add("bg-container-inset")

    const selectedIcon = selectedElement.querySelector(".check-icon")
    if (selectedIcon) selectedIcon.classList.remove("hidden")

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

  scrollToSelected() {
    const selected = this.menuTarget.querySelector(".bg-container-inset")
    const container = this.menuTarget.querySelector('[data-list-filter-target="list"]')

    if (selected && container) {
      const offset =
        selected.offsetTop -
        container.clientHeight / 2 +
        selected.clientHeight / 2

      container.scrollTop = offset
    }
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
