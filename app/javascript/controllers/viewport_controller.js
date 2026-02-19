import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  connect() {
    this.updateViewport()

    this.boundResize = this.handleResize.bind(this)

    window.addEventListener("resize", this.boundResize)
    window.addEventListener("orientationchange", this.boundResize)
  }

  disconnect() {
    window.removeEventListener("resize", this.boundResize)
    window.removeEventListener("orientationchange", this.boundResize)
  }

  handleResize() {
    this.updateViewport()
  }

  updateViewport() {
    const height = window.innerHeight
    document.documentElement.style.setProperty("--app-height", `${height}px`)
  }
}
