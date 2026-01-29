import { Controller } from "@hotwired/stimulus";

// Connects to data-controller="dialog"
export default class extends Controller {
  static targets = ["leftSidebar", "rightSidebar", "mobileSidebar", "leftHandle", "rightHandle"];
  static values = { userId: Number };
  static classes = [
    "expandedSidebar",
    "collapsedSidebar",
    "expandedTransition",
    "collapsedTransition",
  ];

  openMobileSidebar() {
    this.mobileSidebarTarget.classList.remove("hidden");
  }

  closeMobileSidebar() {
    this.mobileSidebarTarget.classList.add("hidden");
  }

  toggleLeftSidebar() {
    const isOpen = !this.leftSidebarTarget.classList.contains("w-0");
    this.#updateUserPreference("show_sidebar", !isOpen);
    this.#toggleSidebarWidth(this.leftSidebarTarget, isOpen);

    if (this.hasLeftHandleTarget) {
      if (isOpen) {
        this.leftHandleTarget.classList.add("hidden");
        this.leftHandleTarget.classList.remove("lg:flex");
      } else {
        this.leftHandleTarget.classList.remove("hidden");
        this.leftHandleTarget.classList.add("lg:flex");
      }
    }
  }

  toggleRightSidebar() {
    const isOpen = !this.rightSidebarTarget.classList.contains("w-0");
    this.#updateUserPreference("show_ai_sidebar", !isOpen);
    this.#toggleSidebarWidth(this.rightSidebarTarget, isOpen);

    if (this.hasRightHandleTarget) {
      if (isOpen) {
        this.rightHandleTarget.classList.add("hidden");
        this.rightHandleTarget.classList.remove("lg:flex");
      } else {
        this.rightHandleTarget.classList.remove("hidden");
        this.rightHandleTarget.classList.add("lg:flex");
      }
    }
  }

  #toggleSidebarWidth(el, isCurrentlyOpen) {
    if (isCurrentlyOpen) {
      el.classList.remove(...this.expandedSidebarClasses);
      el.classList.add(...this.collapsedSidebarClasses);
    } else {
      el.classList.add(...this.expandedSidebarClasses);
      el.classList.remove(...this.collapsedSidebarClasses);
    }
  }

  #updateUserPreference(field, value) {
    fetch(`/users/${this.userIdValue}`, {
      method: "PATCH",
      headers: {
        "Content-Type": "application/x-www-form-urlencoded",
        "X-CSRF-Token": document.querySelector('[name="csrf-token"]').content,
        Accept: "application/json",
      },
      body: new URLSearchParams({
        [`user[${field}]`]: value,
      }).toString(),
    });
  }
}
