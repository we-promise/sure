import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["input", "form", "overlay"]
  static values = { invalidFileMessage: String }

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
    if (!this.isActive()) return
    event.preventDefault()
    this.dragDepth++
    if (this.dragDepth === 1) {
      this.overlayTarget.classList.remove("hidden")
    }
  }

  dragOver(event) {
    if (!this.isActive()) return
    event.preventDefault()
  }

  dragLeave(event) {
    if (!this.isActive()) return
    event.preventDefault()
    this.dragDepth--
    if (this.dragDepth <= 0) {
      this.dragDepth = 0
      this.overlayTarget.classList.add("hidden")
    }
  }

  drop(event) {
    if (!this.isActive()) return
    event.preventDefault()
    this.dragDepth = 0
    this.overlayTarget.classList.add("hidden")

    if (event.dataTransfer.files.length > 0) {
      const files = Array.from(event.dataTransfer.files)
      const acceptedTypes = this.inputTarget.accept.split(",").map((type) => type.trim().toLowerCase()).filter(Boolean)
      const allAccepted = acceptedTypes.length === 0 || files.every((file) => this.matchesAcceptedType(file, acceptedTypes))
      if (allAccepted) {
        this.inputTarget.files = event.dataTransfer.files
        this.inputTarget.dispatchEvent(new Event("change", { bubbles: true }))
      } else {
        alert(this.invalidFileMessageValue || "Please upload files in the selected format.")
      }
    }
  }

  isActive() {
    return this.hasInputTarget && this.hasFormTarget && !this.inputTarget.disabled &&
      !this.element.closest("[hidden]")
  }

  matchesAcceptedType(file, acceptedTypes) {
    return acceptedTypes.some((type) => {
      if (type.startsWith(".")) return file.name.toLowerCase().endsWith(type)
      if (type.endsWith("/*")) return file.type.toLowerCase().startsWith(type.slice(0, -1))
      return file.type.toLowerCase() === type
    })
  }
}
