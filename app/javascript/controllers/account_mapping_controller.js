import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["mapping"]

  createAll() {
    this.mappingTargets.forEach(select => { select.value = "new" })
  }
}
