import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["input", "form", "overlay"]

  dragDepth = 0

  connect() {
    this.boundDragOver = this.dragOver.bind(this)
    this.boundDragEnter = this.dragEnter.bind(this)
    this.boundDragLeave = this.dragLeave.bind(this)
    this.boundDrop = this.drop.bind(this)
    this.boundInternalDragStart = this.internalDragStart.bind(this)
    this.boundInternalDragEnd = this.internalDragEnd.bind(this)

    // Listen on the document to catch drags anywhere
    document.addEventListener("dragover", this.boundDragOver)
    document.addEventListener("dragenter", this.boundDragEnter)
    document.addEventListener("dragleave", this.boundDragLeave)
    document.addEventListener("drop", this.boundDrop)
    // dragstart only fires for drags that begin on the page itself.
    document.addEventListener("dragstart", this.boundInternalDragStart)
    document.addEventListener("dragend", this.boundInternalDragEnd)
  }

  disconnect() {
    document.removeEventListener("dragover", this.boundDragOver)
    document.removeEventListener("dragenter", this.boundDragEnter)
    document.removeEventListener("dragleave", this.boundDragLeave)
    document.removeEventListener("drop", this.boundDrop)
    document.removeEventListener("dragstart", this.boundInternalDragStart)
    document.removeEventListener("dragend", this.boundInternalDragEnd)
  }

  // Dragging an element on the page (e.g. reordering sidebar accounts) must
  // not open the import overlay; only drags from outside the page do.
  internalDragStart(event) {
    // A drag the page cancelled (e.g. a touch-held sortable row) never gets a
    // dragend, so it must not leave the flag set and block later file drops.
    if (event.defaultPrevented) return
    this.internalDrag = true
  }

  internalDragEnd() {
    this.internalDrag = false
  }

  isExternalDrag() {
    return !this.internalDrag
  }

  dragEnter(event) {
    if (!this.isExternalDrag()) return
    event.preventDefault()
    this.dragDepth++
    if (this.dragDepth === 1) {
      this.overlayTarget.classList.remove("hidden")
    }
  }

  dragOver(event) {
    if (!this.isExternalDrag()) return
    event.preventDefault()
  }

  dragLeave(event) {
    if (!this.isExternalDrag()) return
    event.preventDefault()
    this.dragDepth--
    if (this.dragDepth <= 0) {
      this.dragDepth = 0
      this.overlayTarget.classList.add("hidden")
    }
  }

  drop(event) {
    if (!this.isExternalDrag()) {
      // In case the dragged row left the page before its dragend fired.
      this.internalDrag = false
      return
    }
    event.preventDefault()
    this.dragDepth = 0
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
