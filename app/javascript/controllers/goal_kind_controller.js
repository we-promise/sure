import { Controller } from "@hotwired/stimulus"

// A maintained reserve has no deadline: it is a target balance to hold, not
// something due on a date. Hiding the target-date field keeps a stale value from being
// submitted and driving a pace the goal does not have.
export default class extends Controller {
  static targets = ["radio", "dateField", "modeField", "modeSelect", "monthsField", "amountField", "amountDerived"]

  static values = {
    amountLabel: String,
    balanceLabel: String,
    derivable: Boolean,
  }

  connect() {
    this.refresh()
  }

  refresh() {
    const maintained = this.radioTargets.some((radio) => radio.checked && radio.value === "maintained")

    this.dateFieldTargets.forEach((field) => field.classList.toggle("hidden", maintained))
    if (maintained) this.#clearInputs(this.dateFieldTargets)

    // The target mode is a reserve's business only; a one-off is always a
    // fixed amount. Reset it on the way out so a one-off cannot be saved
    // carrying a months mode nothing would ever refresh.
    this.modeFieldTargets.forEach((field) => field.classList.toggle("hidden", !maintained))
    if (!maintained && this.hasModeSelectTarget) this.modeSelectTarget.value = "fixed"

    const months = maintained && this.hasModeSelectTarget && this.modeSelectTarget.value === "months_of_expenses"
    this.monthsFieldTargets.forEach((field) => field.classList.toggle("hidden", !months))
    if (!months) this.#clearInputs(this.monthsFieldTargets)

    // Three states. A one-off saves toward a target amount; a fixed reserve
    // holds a target balance you type; a months-based reserve holds one worked
    // out from spending, so the input gives way to the figure itself — a
    // greyed-out input still reads as something to fill in, beside the months
    // that are the actual question.
    //
    // Only where there IS spending to work one out from, though. With none the
    // model keeps whatever was typed, so the field has to stay: it is then the
    // only way to give the reserve a target at all.
    const derived = months && this.derivableValue
    this.amountFieldTargets.forEach((field) => field.classList.toggle("hidden", derived))
    this.amountDerivedTargets.forEach((field) => field.classList.toggle("hidden", !derived))

    // Disabled, not merely hidden. A `required` input is still validated by
    // the browser while `display: none`, which then blocks a submit it cannot
    // show the error on — the reserve became impossible to create. Disabling
    // also keeps the typed figure out of the params, so what lands is the
    // figure the model derived.
    this.amountFieldTargets.forEach((field) => {
      field.querySelectorAll("input").forEach((input) => { input.disabled = derived })
    })

    // Only the wording changes. Assigning `textContent` would replace every
    // child of the label, and the label carries the required-field asterisk in
    // a span of its own — wiped on the first `refresh()`, which runs on connect
    // for every goal form, with nothing to put it back.
    const label = maintained ? this.balanceLabelValue : this.amountLabelValue
    this.amountFieldTargets.forEach((field) => {
      const el = field.querySelector(".form-field__label")
      if (!el || !label) return

      const wording = [...el.childNodes].find(
        (node) => node.nodeType === Node.TEXT_NODE && node.textContent.trim(),
      )
      if (wording) wording.textContent = label
      else el.prepend(document.createTextNode(label))
    })
  }

  #clearInputs(fields) {
    fields.forEach((field) => {
      const input = field.querySelector("input")
      if (!input) return

      input.value = ""
      // Assigning `value` fires nothing, so the pace suggestion bound to this
      // input's action kept showing a monthly figure derived from a deadline
      // the goal no longer has.
      input.dispatchEvent(new Event("input", { bubbles: true }))
    })
  }
}
