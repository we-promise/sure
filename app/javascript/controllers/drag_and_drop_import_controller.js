import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["input", "form", "overlay"]

  connect() {
    this.boundDragOver = this.dragOver.bind(this)
    this.boundDragLeave = this.dragLeave.bind(this)
    this.boundDrop = this.drop.bind(this)

    // Listen on the document to catch drags anywhere
    document.addEventListener("dragover", this.boundDragOver)
    document.addEventListener("dragleave", this.boundDragLeave)
    document.addEventListener("drop", this.boundDrop)
  }

  disconnect() {
    document.removeEventListener("dragover", this.boundDragOver)
    document.removeEventListener("dragleave", this.boundDragLeave)
    document.removeEventListener("drop", this.boundDrop)
  }

  dragOver(event) {
    event.preventDefault()
    this.overlayTarget.classList.remove("hidden")
  }

  dragLeave(event) {
    event.preventDefault()
    // If we are leaving the window (client coordinates are 0 or outside bounds), hide overlay
    if (event.clientX === 0 || event.clientY === 0 || event.pageX === 0 || event.pageY === 0) {
      this.overlayTarget.classList.add("hidden")
    }
    
    // Also hide if we clicked 'Esc' or something (handled by browser usually but good to know)
    // Actually, dragleave fires when entering a child element too, so we must check.
    // But since the overlay covers everything (z-index), we only leave if we leave the overlay?
    // If the overlay has pointer-events: none, we drag over elements below.
    
    // Better logic: rely on dragEnter on the overlay?
    // If we attach to document, we get dragover constantly.
  }

  drop(event) {
    event.preventDefault()
    this.overlayTarget.classList.add("hidden")

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
}
