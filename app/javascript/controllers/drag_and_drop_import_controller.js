import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["input", "form", "overlay"]

  dragDepth = 0

  connect() {
    this.boundDragOver = this.dragOver.bind(this)
    this.boundDragEnter = this.dragEnter.bind(this)
    this.boundDragLeave = this.dragLeave.bind(this)
    this.boundDrop = this.drop.bind(this)

    // Listen on the document to catch drags anywhere
    document.addEventListener("dragover", this.boundDragOver)
    document.addEventListener("dragenter", this.boundDragEnter)
    document.addEventListener("dragleave", this.boundDragLeave)
    document.addEventListener("drop", this.boundDrop)
  }

  disconnect() {
    document.removeEventListener("dragover", this.boundDragOver)
    document.removeEventListener("dragenter", this.boundDragEnter)
    document.removeEventListener("dragleave", this.boundDragLeave)
    document.removeEventListener("drop", this.boundDrop)
  }

  dragEnter(event) {
    event.preventDefault()
    this.dragDepth++
    if (this.dragDepth === 1) {
      this.showOverlay()
    }
  }

  dragOver(event) {
    event.preventDefault()
  }

  dragLeave(event) {
    event.preventDefault()
    this.dragDepth--
    if (this.dragDepth <= 0) {
      this.dragDepth = 0
      this.hideOverlay()
    }
  }

  drop(event) {
    event.preventDefault()
    this.dragDepth = 0
    this.hideOverlay()

    if (event.dataTransfer.files.length > 0) {
      const file = event.dataTransfer.files[0]
      // Simple validation
      if (file.type === "text/csv" || file.name.toLowerCase().endsWith(".csv")) {
        this.inputTarget.files = event.dataTransfer.files
        this.formTarget.requestSubmit()
      } else {
        alert("Please upload a valid CSV file.")
      }
    }
  }

  showOverlay() {
    this.overlayTarget.classList.remove("hidden")
    this.overlayTarget.classList.add("flex")
  }

  hideOverlay() {
    this.overlayTarget.classList.add("hidden")
    this.overlayTarget.classList.remove("flex")
  }
}
