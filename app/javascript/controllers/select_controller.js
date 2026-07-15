import { Controller } from "@hotwired/stimulus"
import { autoUpdate } from "@floating-ui/dom"

export default class extends Controller {
  static targets = ["button", "menu", "input", "content", "option"]
  static values = {
    menuPlacement: { type: String, default: "auto" },
    offset: { type: Number, default: 6 }
  }

  connect() {
    this.isOpen = false
    this.boundOutsideClick = this.handleOutsideClick.bind(this)
    this.boundKeydown = this.handleKeydown.bind(this)
    this.boundTurboLoad = this.handleTurboLoad.bind(this)
    this.boundFocusOut = this.handleFocusOut.bind(this)

    document.addEventListener("click", this.boundOutsideClick)
    document.addEventListener("turbo:load", this.boundTurboLoad)
    this.element.addEventListener("keydown", this.boundKeydown)
    this.element.addEventListener("focusout", this.boundFocusOut)

    this.resetOptionTabindex()
    this.setMenuInert(true)
    this.observeMenuResize()
  }

  disconnect() {
    document.removeEventListener("click", this.boundOutsideClick)
    document.removeEventListener("turbo:load", this.boundTurboLoad)
    this.element.removeEventListener("keydown", this.boundKeydown)
    this.element.removeEventListener("focusout", this.boundFocusOut)
    this.stopAutoUpdate()
    if (this.resizeObserver) this.resizeObserver.disconnect()
  }

  toggle = () => {
    this.isOpen ? this.close() : this.openMenu()
  }

  // Tab lands on the trigger — open the menu but keep focus here so the
  // browser doesn't continue Tab into the listbox and skip to the next field.
  handleButtonFocus() {
    if (this.isOpen) return
    if (!this.buttonTarget.matches(":focus-visible")) return
    this.openMenu()
  }

  // Arrow / Space / Enter from a closed trigger — open and move focus in.
  openAndFocusMenu() {
    this.openMenu()
    requestAnimationFrame(() => {
      if (this.focusSearch()) return
      this.focusSelectedOrFirstOption()
    })
  }

  focusSelectedOrFirstOption() {
    const visible = this.visibleOptions()
    if (visible.length === 0) return

    const selected = visible.find(opt => opt.getAttribute("aria-selected") === "true")
    this.focusOption(selected || visible[0])
  }

  openMenu() {
    this.isOpen = true
    this.setMenuInert(false)
    this.menuTarget.classList.remove("hidden")
    this.buttonTarget.setAttribute("aria-expanded", "true")
    this.startAutoUpdate()
    this.clearSearch()
    requestAnimationFrame(() => {
      this.menuTarget.classList.remove("opacity-0", "-translate-y-1", "pointer-events-none")
      this.menuTarget.classList.add("opacity-100", "translate-y-0")
      this.updatePosition()
      this.scrollToSelected()
    })
  }

  close() {
    this.isOpen = false
    this.stopAutoUpdate()
    this.menuTarget.classList.remove("opacity-100", "translate-y-0")
    this.menuTarget.classList.add("opacity-0", "-translate-y-1", "pointer-events-none")
    this.buttonTarget.setAttribute("aria-expanded", "false")
    this.resetOptionTabindex()
    this.setMenuInert(true)
    setTimeout(() => { if (!this.isOpen && this.hasMenuTarget) this.menuTarget.classList.add("hidden") }, 150)
  }

  select(event) {
    const selectedElement = event.currentTarget
    const value = selectedElement.dataset.value
    const label = selectedElement.dataset.filterName || selectedElement.textContent.trim()

    this.buttonTarget.textContent = label
    if (this.hasInputTarget) {
      this.inputTarget.value = value
      this.inputTarget.dispatchEvent(new Event("change", { bubbles: true }))
    }

    const previousSelected = this.menuTarget.querySelector("[aria-selected='true']")
    if (previousSelected) {
      previousSelected.setAttribute("aria-selected", "false")
      previousSelected.classList.remove("bg-container-inset")
      const prevIcon = previousSelected.querySelector(".check-icon")
      if (prevIcon) prevIcon.classList.add("hidden")
    }

    selectedElement.setAttribute("aria-selected", "true")
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
    if (!selected) return

    const container = this.hasContentTarget ? this.contentTarget : this.menuTarget
    const containerRect = container.getBoundingClientRect()
    const selectedRect = selected.getBoundingClientRect()
    const delta = selectedRect.top - containerRect.top - (container.clientHeight - selectedRect.height) / 2

    const nextScrollTop = container.scrollTop + delta
    const maxScrollTop = Math.max(0, container.scrollHeight - container.clientHeight)
    container.scrollTop = this.clamp(nextScrollTop, 0, maxScrollTop)
  }

  clamp(value, min, max) {
    return Math.min(max, Math.max(min, value))
  }

  placementMode() {
    const mode = (this.menuPlacementValue || "auto").toLowerCase()
    return ["auto", "down", "up"].includes(mode) ? mode : "auto"
  }

  handleOutsideClick(event) {
    if (this.isOpen && !this.element.contains(event.target)) this.close()
  }

  handleFocusOut(event) {
    if (!this.isOpen) return
    const related = event.relatedTarget
    if (related && this.element.contains(related)) return
    this.close()
  }

  handleKeydown(event) {
    if (!this.isOpen && event.target === this.buttonTarget) {
      if (["ArrowDown", "ArrowUp", " ", "Enter"].includes(event.key)) {
        event.preventDefault()
        this.openAndFocusMenu()
      }
      return
    }

    if (!this.isOpen) return

    if (event.key === "Tab") {
      this.close()
      return
    }

    if (event.key === "Escape") { this.close(); this.buttonTarget.focus(); return }
    if (event.key === "Enter" && event.target.dataset.value) { event.preventDefault(); event.target.click(); return }

    // WAI-ARIA APG listbox keyboard pattern: ArrowUp/Down moves focus
    // between options, Home/End jump to first/last. Options stay at
    // tabindex="-1" so they never appear in the Tab sequence — focus moves
    // programmatically only.
    // From the search input, ArrowDown/Up bridge into the visible options.
    const fromSearch = event.target.matches('input[type="search"]')
    const fromButton = event.target === this.buttonTarget
    const visibleOptions = this.visibleOptions()

    if (fromSearch) {
      if (event.key !== "ArrowDown" && event.key !== "ArrowUp") return
      if (visibleOptions.length === 0) return
      event.preventDefault()
      const targetIndex = event.key === "ArrowDown" ? 0 : visibleOptions.length - 1
      this.focusOption(visibleOptions[targetIndex])
      return
    }

    if (fromButton && event.key === "ArrowDown" && this.focusSearch()) {
      event.preventDefault()
      return
    }

    if (visibleOptions.length === 0) return
    const currentIndex = visibleOptions.indexOf(event.target)
    let nextIndex = null
    switch (event.key) {
      case "ArrowDown": nextIndex = currentIndex < 0 ? 0 : (currentIndex + 1) % visibleOptions.length; break
      case "ArrowUp": nextIndex = currentIndex < 0 ? visibleOptions.length - 1 : (currentIndex - 1 + visibleOptions.length) % visibleOptions.length; break
      case "Home": nextIndex = 0; break
      case "End": nextIndex = visibleOptions.length - 1; break
      default: return
    }
    event.preventDefault()
    this.focusOption(visibleOptions[nextIndex])
  }

  focusOption(option) {
    if (!option) return
    option.focus({ preventScroll: true })
    option.scrollIntoView({ block: "nearest" })
  }

  resetOptionTabindex() {
    if (!this.hasOptionTarget) return
    this.optionTargets.forEach(opt => opt.setAttribute("tabindex", "-1"))
  }

  setMenuInert(inert) {
    if (!this.hasMenuTarget) return
    if (inert) {
      this.menuTarget.setAttribute("inert", "")
    } else {
      this.menuTarget.removeAttribute("inert")
    }
  }

  // Options the user can currently see — list-filter hides non-matches
  // by setting `style.display = "none"`. Inline check keeps it cheap.
  visibleOptions() {
    const options = this.hasOptionTarget ? this.optionTargets : []
    return options.filter(opt => opt.style.display !== "none")
  }

  // After list-filter#filter runs, the focused option may be hidden.
  // Move focus to the first visible match without touching tabindex.
  syncTabindex() {
    const visible = this.visibleOptions()
    if (visible.length === 0) return

    const active = document.activeElement
    if (visible.includes(active)) return

    this.focusOption(visible[0])
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
    const placement = this.placementMode()
    const shouldOpenUp = placement === "up" || (placement === "auto" && spaceBelow < menuHeight && spaceAbove > spaceBelow)

    this.menuTarget.style.left = "0"
    this.menuTarget.style.width = "100%"
    this.menuTarget.style.top = ""
    this.menuTarget.style.bottom = ""
    this.menuTarget.style.overflowY = "auto"

    if (shouldOpenUp) {
      this.menuTarget.style.bottom = "100%"
      this.menuTarget.style.maxHeight = `${Math.max(0, spaceAbove - this.offsetValue)}px`
    } else {
      this.menuTarget.style.top = "100%"
      this.menuTarget.style.maxHeight = `${Math.max(0, spaceBelow - this.offsetValue)}px`
    }
  }
}
