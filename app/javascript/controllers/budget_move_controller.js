import { Controller } from "@hotwired/stimulus"

// Drives the single move dialog shared by every category row on the budget
// allocation page. One dialog for the page rather than one per row: the list
// can hold dozens of categories, and they would all be identical but for the
// source.
//
// The dialog itself is a DS::Dialog, so focus trapping, Escape, click-outside
// and focus restore are its job, not this controller's. What is left here is
// what the component cannot know: which row opened it, and where the money is
// allowed to go.
//
// Options that the server would refuse anyway are disabled rather than left
// selectable — a category cannot send money to itself, nor to its own parent
// or child, because the parent's allocation is derived from its children's.
export default class extends Controller {
  static targets = [
    "dialog",
    "fromId",
    "fromName",
    "available",
    "toSelect",
    "amount",
    "submit",
    "noDestination",
  ]

  open({ params }) {
    this.fromIdTarget.value = params.fromId
    this.fromNameTarget.textContent = params.fromName
    this.availableTarget.textContent = params.available
    this.amountTarget.value = ""

    this.#refreshOptions(String(params.fromId), String(params.categoryId), String(params.parentId || ""))
    this.dialogTarget.showModal()
    this.amountTarget.focus()
  }

  close() {
    this.#dialogController()?.close() ?? this.dialogTarget.close()
  }

  // Closing on submit alone would hide the reason a move was refused. Only a
  // response Turbo considers successful ends the interaction.
  submitEnd(event) {
    if (event.detail?.success) this.close()
  }

  #refreshOptions(fromId, categoryId, parentId) {
    let firstEnabled = null

    for (const option of this.toSelectTarget.options) {
      const optionCategoryId = option.dataset.categoryId
      const optionParentId = option.dataset.parentId || ""

      option.disabled =
        option.value === fromId ||
        optionCategoryId === parentId ||
        optionParentId === categoryId

      if (!option.disabled && firstEnabled === null) firstEnabled = option
    }

    if (firstEnabled) this.toSelectTarget.value = firstEnabled.value

    // A lone envelope, or one whose only peers are its own parent and
    // children, has nowhere to send money. Leaving submit enabled offers a
    // button whose only outcome is a server error.
    const hasDestination = firstEnabled !== null
    this.submitTarget.disabled = !hasDestination
    this.toSelectTarget.disabled = !hasDestination
    this.amountTarget.disabled = !hasDestination
    this.noDestinationTarget.classList.toggle("hidden", hasDestination)
  }

  #dialogController() {
    return this.application.getControllerForElementAndIdentifier(this.dialogTarget, "DS--dialog")
  }
}
