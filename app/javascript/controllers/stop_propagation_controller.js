import { Controller } from "@hotwired/stimulus";

// Generic click-guard for elements nested inside a larger clickable/label
// area (e.g. a date input inside an account row that toggles selection on
// click). A strict script-src CSP blocks inline onclick="..." handlers, so
// this replaces every such handler in the app.
export default class extends Controller {
  stop(event) {
    event.stopPropagation();
  }
}
