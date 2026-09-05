import { Controller } from "@hotwired/stimulus";

// Navigates back in browser history. A strict script-src CSP blocks
// `javascript:` URLs (they're treated as inline script, same as
// onclick="..."), so this replaces any `href="javascript:history.back()"`.
export default class extends Controller {
  back(event) {
    event.preventDefault();
    window.history.back();
  }
}
