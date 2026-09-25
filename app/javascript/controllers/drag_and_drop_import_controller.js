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
      this.overlayTarget.classList.remove("hidden")
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
      this.overlayTarget.classList.add("hidden")
    }
  }

  drop(event) {
    event.preventDefault()
    this.dragDepth = 0
    this.overlayTarget.classList.add("hidden")

    if (event.dataTransfer.files.length > 0) {
      const file = event.dataTransfer.files[0]
      if (this.accepts(file)) {
        this.inputTarget.files = event.dataTransfer.files
        this.formTarget.requestSubmit()
      } else {
        alert("Please upload a supported file.")
      }
    }
  }

  accepts(file) {
    const accepted = (this.inputTarget.accept || "").split(",").map((value) => value.trim().toLowerCase())
    const filename = file.name.toLowerCase()

    return accepted.length === 0 || accepted.some((value) =>
      value.startsWith(".") ? filename.endsWith(value) : file.type.toLowerCase() === value
    )
  }
}
