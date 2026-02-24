import { Controller } from "@hotwired/stimulus"
import { autoUpdate } from "@floating-ui/dom"

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
    this.boundTurboLoad = this.handleTurboLoad.bind(this)

    document.addEventListener("click", this.boundOutsideClick)
    document.addEventListener("turbo:load", this.boundTurboLoad)
    this.element.addEventListener("keydown", this.boundKeydown)

    this.startAutoUpdate()
    this.observeMenuResize()
  }

  disconnect() {
    document.removeEventListener("click", this.boundOutsideClick)
    document.removeEventListener("turbo:load", this.boundTurboLoad)
    this.element.removeEventListener("keydown", this.boundKeydown)
    this.stopAutoUpdate()
    if (this.resizeObserver) this.resizeObserver.disconnect()
  }

  toggle = () => {
    this.isOpen ? this.close() : this.openMenu()
  }

  openMenu() {
    this.isOpen = true
    this.menuTarget.classList.remove("hidden")
    this.clearSearch()
    requestAnimationFrame(() => {
      this.menuTarget.classList.remove("opacity-0", "scale-95", "translate-y-1", "pointer-events-none")
      this.menuTarget.classList.add("opacity-100", "scale-100", "translate-y-0")
      this.updatePosition()
      this.scrollToSelected()
    })
  }

  close() {
    this.isOpen = false
    this.menuTarget.classList.remove("opacity-100", "translate-y-0")
    this.menuTarget.classList.add("opacity-0", "-translate-y-1", "pointer-events-none")
    setTimeout(() => { if (!this.isOpen) this.menuTarget.classList.add("hidden") }, 150)
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

    this.element.dispatchEvent(new CustomEvent("dropdown:select", {
      detail: { value, label },
      bubbles: true
    }))

    this.close()
    this.buttonTarget.focus()
  }

  focusSearch() {
    const input = this.menuTarget.querySelector('input[type="search"]')
    if (input) { input.focus({ preventScroll: true }); return true }
    return false
  }

  focusFirstElement() {
    const selector = 'button, [href], input, select, textarea, [tabindex]:not([tabindex="-1"])'
    const el = this.menuTarget.querySelector(selector)
    if (el) el.focus({ preventScroll: true })
  }

  scrollToSelected() {
    const selected = this.menuTarget.querySelector(".bg-container-inset")
    if (selected) selected.scrollIntoView({ block: "center" })
  }

  handleOutsideClick(event) {
    if (this.isOpen && !this.element.contains(event.target)) this.close()
  }

  handleKeydown(event) {
    if (!this.isOpen) return
    if (event.key === "Escape") { this.close(); this.buttonTarget.focus() }
    if (event.key === "Enter" && event.target.dataset.value) { event.preventDefault(); event.target.click() }
  }

  handleTurboLoad() { if (this.isOpen) this.close() }

  clearSearch() {
    const input = this.menuTarget.querySelector('input[type="search"]')
    if (!input) return
    input.value = ""
    input.dispatchEvent(new Event("input", { bubbles: true }))
  }

  startAutoUpdate() {
    if (!this._cleanup && this.buttonTarget && this.menuTarget) {
      this._cleanup = autoUpdate(this.buttonTarget, this.menuTarget, () => this.updatePosition())
    }
  }

  stopAutoUpdate() {
    if (this._cleanup) { this._cleanup(); this._cleanup = null }
  }

  observeMenuResize() {
    this.resizeObserver = new ResizeObserver(() => {
      if (this.isOpen) requestAnimationFrame(() => this.updatePosition())
    })
    this.resizeObserver.observe(this.menuTarget)
  }

  getScrollParent(element) {
    let parent = element.parentElement
    while (parent) {
      const style = getComputedStyle(parent)
      const overflowY = style.overflowY
      if (overflowY === "auto" || overflowY === "scroll") return parent
      parent = parent.parentElement
    }
    return document.documentElement
  }

  updatePosition() {
    if (!this.buttonTarget || !this.menuTarget || !this.isOpen) return

    const container = this.getScrollParent(this.element)
    const containerRect = container.getBoundingClientRect()
    const buttonRect = this.buttonTarget.getBoundingClientRect()
    const menuHeight = this.menuTarget.scrollHeight

    const spaceBelow = containerRect.bottom - buttonRect.bottom
    const spaceAbove = buttonRect.top - containerRect.top
    const shouldOpenUp = spaceBelow < menuHeight && spaceAbove > spaceBelow

    this.menuTarget.style.left = "0"
    this.menuTarget.style.width = `${this.buttonTarget.offsetWidth}px`
    this.menuTarget.style.top = ""
    this.menuTarget.style.bottom = ""
    this.menuTarget.style.overflowY = "auto"

    if (shouldOpenUp) {
      this.menuTarget.style.bottom = "100%"
      this.menuTarget.style.maxHeight = `${spaceAbove - 8}px`
    } else {
      this.menuTarget.style.top = "100%"
      this.menuTarget.style.maxHeight = `${spaceBelow - 8}px`
    }
  }
}