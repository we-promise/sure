import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["content", "bottomNav"]

  connect() {
    this.updateViewport()
    this.updateBottomSpacing()

    window.addEventListener("resize", this.handleResize)
    window.addEventListener("orientationchange", this.handleResize)

    if (this.hasBottomNavTarget) {
      this.resizeObserver = new ResizeObserver(() => {
        this.updateBottomSpacing()
      })
      this.resizeObserver.observe(this.bottomNavTarget)
    }
  }

  disconnect() {
    window.removeEventListener("resize", this.handleResize)
    window.removeEventListener("orientationchange", this.handleResize)

    if (this.resizeObserver) {
      this.resizeObserver.disconnect()
    }
  }

  handleResize = () => {
    this.updateViewport()
    this.updateBottomSpacing()
  }

  updateViewport() {
    const height = window.innerHeight
    document.documentElement.style.setProperty("--app-height", `${height}px`)
  }

  updateBottomSpacing() {
    if (!this.hasBottomNavTarget || !this.hasContentTarget) return

    const navHeight = this.bottomNavTarget.offsetHeight
    this.contentTarget.style.paddingBottom = `${navHeight}px`
  }
}
