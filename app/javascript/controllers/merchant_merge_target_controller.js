import { Controller } from "@hotwired/stimulus"

const DISABLED_CLASSES = ["opacity-50", "pointer-events-none"]

export default class extends Controller {
  static targets = [
    "existingSection",
    "existingTarget",
    "newSection",
    "newTextInput",
    "newColorInput"
  ]
  static values = { defaultColor: String }

  connect() {
    this.sync()
  }

  sync() {
    const existingTargetSelected = this.existingTargetSelected()
    const newTargetStarted = this.newTargetStarted()

    if (existingTargetSelected) {
      this.clearNewTargetFields()
    } else if (newTargetStarted) {
      this.clearExistingTarget()
    }

    this.setSectionDisabled(this.existingSectionTarget, !existingTargetSelected && newTargetStarted)
    this.setSectionDisabled(this.newSectionTarget, existingTargetSelected)
  }

  beforeSubmit() {
    this.sync()
  }

  newTargetStarted() {
    const textEntered = this.newTextInputTargets.some((input) => input.value.trim() !== "")
    const colorChanged = this.hasNewColorInputTarget &&
      this.defaultColorValue &&
      this.newColorInputTarget.value.toLowerCase() !== this.defaultColorValue.toLowerCase()

    return textEntered || colorChanged
  }

  existingTargetSelected() {
    return this.hasExistingTargetTarget && this.existingTargetTarget.value !== ""
  }

  clearExistingTarget() {
    if (this.hasExistingTargetTarget) this.existingTargetTarget.value = ""
  }

  clearNewTargetFields() {
    this.newTextInputTargets.forEach((input) => {
      input.value = ""
    })

    if (this.hasNewColorInputTarget && this.defaultColorValue) {
      this.newColorInputTarget.value = this.defaultColorValue
    }
  }

  setSectionDisabled(section, disabled) {
    section.setAttribute("aria-disabled", disabled.toString())
    section.classList.toggle("cursor-not-allowed", disabled)
    DISABLED_CLASSES.forEach((className) => section.classList.toggle(className, disabled))

    section.querySelectorAll("input, button, select, textarea").forEach((input) => {
      input.disabled = disabled
    })
  }
}
