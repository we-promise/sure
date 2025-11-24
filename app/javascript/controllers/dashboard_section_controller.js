import { Controller } from "@hotwired/stimulus";

export default class extends Controller {
  static targets = ["content", "chevron", "container", "button"];
  static values = {
    sectionKey: String,
    collapsed: Boolean,
  };

  connect() {
    if (this.collapsedValue) {
      this.collapse(false);
    }
  }

  toggle(event) {
    event.preventDefault();
    if (this.collapsedValue) {
      this.expand();
    } else {
      this.collapse();
    }
  }

  handleToggleKeydown(event) {
    // Handle Enter and Space keys for keyboard accessibility
    if (event.key === "Enter" || event.key === " ") {
      event.preventDefault();
      event.stopPropagation(); // Prevent section's keyboard handler from firing
      this.toggle(event);
    }
  }

  collapse(persist = true) {
    this.contentTarget.classList.add("hidden");
    this.chevronTarget.classList.add("rotate-180");
    this.collapsedValue = true;
    if (this.hasButtonTarget) {
      this.buttonTarget.setAttribute("aria-expanded", "false");
    }
    if (persist) {
      this.savePreference(true);
    }
  }

  expand() {
    this.contentTarget.classList.remove("hidden");
    this.chevronTarget.classList.remove("rotate-180");
    this.collapsedValue = false;
    if (this.hasButtonTarget) {
      this.buttonTarget.setAttribute("aria-expanded", "true");
    }
    this.savePreference(false);
  }

  savePreference(collapsed) {
    const preferences = {
      collapsed_sections: {
        [this.sectionKeyValue]: collapsed,
      },
    };

    fetch("/dashboard/preferences", {
      method: "PATCH",
      headers: {
        "Content-Type": "application/json",
        "X-CSRF-Token": document.querySelector('meta[name="csrf-token"]')
          .content,
      },
      body: JSON.stringify({ preferences }),
    });
  }
}
