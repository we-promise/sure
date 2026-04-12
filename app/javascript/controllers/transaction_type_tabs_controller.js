import { Controller } from "@hotwired/stimulus"

const ACTIVE_CLASSES = ["bg-container", "text-primary", "shadow-sm"]
const INACTIVE_CLASSES = ["hover:bg-container", "text-subdued", "hover:text-primary", "hover:shadow-sm"]
const STORAGE_KEY = "transaction_form_state"

export default class extends Controller {
  static targets = ["tab", "natureField"]

  connect() {
    // Back on the transaction form — any pending submit listener is no longer needed
    this.#removeClearListener()

    const saved = sessionStorage.getItem(STORAGE_KEY)
    if (!saved) return

    sessionStorage.removeItem(STORAGE_KEY)
    this.#restoreState(JSON.parse(saved))
  }

  selectTab(event) {
    event.preventDefault()

    const selectedTab = event.currentTarget
    this.natureFieldTarget.value = selectedTab.dataset.nature

    this.tabTargets.forEach(tab => {
      const isActive = tab === selectedTab
      tab.classList.remove(...(isActive ? INACTIVE_CLASSES : ACTIVE_CLASSES))
      tab.classList.add(...(isActive ? ACTIVE_CLASSES : INACTIVE_CLASSES))
    })
  }

  saveAndNavigate(event) {
    event.preventDefault()

    const state = this.#captureState()
    sessionStorage.setItem(STORAGE_KEY, JSON.stringify(state))

    // If the user submits the transfer form without returning to expense/income,
    // this listener clears the saved state so it doesn't appear next time.
    this.#addClearListener()

    const url = new URL(event.currentTarget.href)
    const amount = state["entry[amount]"]
    if (amount) url.searchParams.set("amount", amount)

    const date = state["entry[date]"]
    if (date) url.searchParams.set("date", date)

    Turbo.visit(url.toString(), { frame: "modal" })
  }

  // private

  #addClearListener() {
    this.#removeClearListener()
    this._clearListener = (e) => {
      if (e.detail.success) {
        sessionStorage.removeItem(STORAGE_KEY)
        this.#removeClearListener()
      }
    }
    document.addEventListener("turbo:submit-end", this._clearListener)
  }

  #removeClearListener() {
    if (this._clearListener) {
      document.removeEventListener("turbo:submit-end", this._clearListener)
      this._clearListener = null
    }
  }

  #captureState() {
    const form = this.element.closest("form")
    if (!form) return {}

    const state = {}

    // Standard visible inputs, selects, textareas
    form.querySelectorAll("input:not([type=hidden]), select, textarea").forEach(el => {
      if (!el.name) return

      if (el.tagName === "SELECT" && el.multiple) {
        state[el.name] = Array.from(el.selectedOptions).map(o => o.value)
      } else {
        state[el.name] = el.value
      }
    })

    // Custom DS::Select components store their value in a hidden input
    form.querySelectorAll("input[data-form-dropdown-target='input']").forEach(el => {
      if (el.name) state[el.name] = el.value
    })

    // Preserve the nature hidden field
    const natureField = form.querySelector("input[name='entry[nature]']")
    if (natureField) state[natureField.name] = natureField.value

    return state
  }

  #restoreState(state) {
    const form = this.element.closest("form")
    if (!form) return

    for (const [name, value] of Object.entries(state)) {
      const el = form.querySelector(`[name="${CSS.escape(name)}"]`)
      if (!el) continue

      if (el.dataset.formDropdownTarget === "input") {
        this.#restoreCustomSelect(el, value)
      } else if (el.tagName === "SELECT" && el.multiple) {
        Array.from(el.options).forEach(opt => {
          opt.selected = value.includes(opt.value)
        })
        el.dispatchEvent(new Event("change", { bubbles: true }))
      } else {
        el.value = value
        el.dispatchEvent(new Event("change", { bubbles: true }))
      }
    }
  }

  #restoreCustomSelect(hiddenInput, value) {
    hiddenInput.value = value

    const container = hiddenInput.closest("[data-controller~='select']")
    if (!container) return

    const option = container.querySelector(`[data-value="${CSS.escape(value)}"]`)
    const button = container.querySelector("[data-select-target='button']")

    if (button) {
      button.textContent = option
        ? (option.dataset.filterName || option.textContent.trim())
        : button.textContent
    }

    container.querySelectorAll("[role='option']").forEach(opt => {
      const isSelected = opt.dataset.value == value
      opt.setAttribute("aria-selected", String(isSelected))
      opt.classList.toggle("bg-container-inset", isSelected)
      opt.querySelector(".check-icon")?.classList.toggle("hidden", !isSelected)
    })

    hiddenInput.dispatchEvent(new Event("change", { bubbles: true }))
  }
}
