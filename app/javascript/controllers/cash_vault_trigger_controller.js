import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static values = { url: String }

  open(event) {
    event.preventDefault()

    if (this.hasUrlValue) {
      window.location.assign(this.urlValue)
    }
  }
}
