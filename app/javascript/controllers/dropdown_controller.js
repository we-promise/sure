import { Controller } from "@hotwired/stimulus"
import { autoUpdate, computePosition, offset, shift } from "@floating-ui/dom"

export default class extends Controller {
  static targets = ["button", "menu", "input"]
  static values = {
    placement: { type: String, default: "bottom-start" },
    offset: { type: Number, default: 6 }
  }

  connect() {
    this.isOpen = false
    this.boundOutsideClick = this.handleOutsideClick.bind(this)
    this.boundKeydown = this.handleKeydown.bind(this)

    document.addEventListener("click", this.boundOutsideClick)
    this.element.addEventListener("keydown", this.boundKeydown)

    this.startAutoUpdate()
  }

  disconnect() {
    document.removeEventListener("click", this.boundOutsideClick)
    this.element.removeEventListener("keydown", this.boundKeydown)
    this.stopAutoUpdate()
  }

  toggle = () => {
    this.isOpen ? this.close() : this.openMenu()
  }

  openMenu() {
    this.isOpen = true
    this.menuTarget.classList.remove("hidden")
    this.updatePosition()
    this.scrollToSelected()
    this.focusSearch()
  }

  close() {
    this.isOpen = false
    this.menuTarget.classList.add("hidden")
  }

  select(event) {
    const selectedElement = event.currentTarget
    const value = selectedElement.dataset.value
    const label = selectedElement.dataset.filterName || selectedElement.textContent.trim()

    this.buttonTarget.textContent = label
    if (this.hasInputTarget) this.inputTarget.value = value

    const previousSelected = this.menuTarget.querySelector(".bg-container-inset")
    if (previousSelected) {
      previousSelected.classList.remove("bg-container-inset")
      const prevIcon = previousSelected.querySelector(".check-icon")
      if (prevIcon) prevIcon.classList.add("hidden")
    }

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
    if (selected) {
      selected.scrollIntoView({
        block: "center",
        behavior: "instant"
      })
    }
  }

  handleOutsideClick(event) {
    if (this.isOpen && !this.element.contains(event.target)) {
      this.close()
    }
  }

  handleKeydown(event) {
    if (!this.isOpen) return

    if (event.key === "Escape") {
      this.close()
      this.buttonTarget.focus()
    }

    if (event.key === "Enter" && event.target.dataset.value) {
      event.preventDefault()
      event.target.click()
    }
  }

  startAutoUpdate() {
    if (!this._cleanup && this.buttonTarget && this.menuTarget) {
      this._cleanup = autoUpdate(
        this.buttonTarget,
        this.menuTarget,
        () => this.updatePosition()
      )
    }
  }

  stopAutoUpdate() {
    if (this._cleanup) {
      this._cleanup()
      this._cleanup = null
    }
  }

  updatePosition() {
    if (!this.buttonTarget || !this.menuTarget) return;

    const containerRect = this.element.getBoundingClientRect();
    computePosition(this.buttonTarget, this.menuTarget, {
      placement: this.placementValue,
      middleware: [offset(this.offsetValue), shift({ padding: 5 })],
      strategy: "fixed"
    }).then(() => {
      Object.assign(this.menuTarget.style, {
        position: "fixed",
        left: `${containerRect.left}px`,
        top: `${containerRect.bottom + this.offsetValue}px`,
        width: `${containerRect.width}px`
      });
    });
  }
}