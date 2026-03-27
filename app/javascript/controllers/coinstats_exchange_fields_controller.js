import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["select", "fields", "connectionName"]
  static values = {
    exchanges: Array,
    initialConnectionId: String,
    initialFields: Object
  }

  connect() {
    if (this.hasSelectTarget && this.initialConnectionIdValue && !this.selectTarget.value) {
      this.selectTarget.value = this.initialConnectionIdValue
    }

    this.render()
  }

  render() {
    if (!this.hasFieldsTarget || !this.hasSelectTarget) return

    const exchange = this.exchangesValue.find((entry) => entry.connection_id === this.selectTarget.value)
    this.fieldsTarget.innerHTML = ""

    if (!exchange) {
      if (this.hasConnectionNameTarget) this.connectionNameTarget.value = ""
      return
    }

    if (this.hasConnectionNameTarget) {
      this.connectionNameTarget.value = exchange.name || ""
    }

    exchange.connection_fields.forEach((field) => {
      const wrapper = document.createElement("div")
      wrapper.className = "space-y-1"

      const label = document.createElement("label")
      label.className = "block text-sm font-medium text-primary"
      label.setAttribute("for", `coinstats_exchange_${field.key}`)
      label.textContent = field.name

      const input = document.createElement("input")
      input.id = `coinstats_exchange_${field.key}`
      input.name = `connection_fields[${field.key}]`
      input.type = this.inputTypeFor(field.key)
      input.autocomplete = "off"
      input.className = "block w-full rounded-md border border-primary px-3 py-2 text-sm bg-container-inset text-primary placeholder:text-secondary focus:border-primary focus:ring-0"
      input.placeholder = field.name
      input.value = this.initialFieldsValue?.[field.key] || ""

      wrapper.appendChild(label)
      wrapper.appendChild(input)
      this.fieldsTarget.appendChild(wrapper)
    })
  }

  inputTypeFor(key) {
    return /secret|password|token|passphrase|private/i.test(key) ? "password" : "text"
  }
}
