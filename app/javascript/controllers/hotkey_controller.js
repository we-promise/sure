import { install, uninstall } from "@github/hotkey";
import { Controller } from "@hotwired/stimulus";

// Connects to data-controller="hotkey"
export default class extends Controller {
  connect() {
    this.installed = false;
    document.addEventListener("keydown", this.syncInstall, true);
    this.syncInstall();
  }

  disconnect() {
    document.removeEventListener("keydown", this.syncInstall, true);
    if (this.installed) uninstall(this.element);
  }

  navigateBack(event) {
    window.history.back();
  }

  // Takes this hotkey out of @github/hotkey for keys it shouldn't answer:
  // - Keys pressed in a modal dialog this hotkey isn't part of. The library
  //   would click it through the inert page, and swallow the key, so Escape
  //   couldn't close the dialog.
  // - A held key's auto-repeats, for a link. Each one would start the same
  //   Turbo visit over again.
  // Added in connect(), not as a data-action, so no hotkey can miss it, and in
  // the capture phase so it runs before the library's own keydown listener.
  syncInstall = (event) => {
    const modal =
      event?.target.closest?.("dialog:modal") ??
      document.querySelector("dialog:modal");
    const heldLink = event?.repeat && this.element.matches("a[href]");
    const active = (!modal || modal.contains(this.element)) && !heldLink;
    if (active === this.installed) return;

    if (active) install(this.element);
    else uninstall(this.element);
    this.installed = active;
  };
}
