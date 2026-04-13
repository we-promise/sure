import { Controller } from "@hotwired/stimulus";

// Connects to data-controller="dialog"
export default class extends Controller {
  static targets = ["leftSidebar", "rightSidebar", "mobileSidebar"];
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
    const isOpen = this.leftSidebarTarget.classList.contains("w-full");
    this.#updateUserPreference("show_sidebar", !isOpen);
    this.#toggleSidebarWidth(this.leftSidebarTarget, isOpen, "left");
  }

  toggleRightSidebar() {
    const isOpen = this.rightSidebarTarget.classList.contains("w-full");
    this.#updateUserPreference("show_ai_sidebar", !isOpen);
    this.#toggleSidebarWidth(this.rightSidebarTarget, isOpen, "right");
  }

  #toggleSidebarWidth(el, isCurrentlyOpen, side) {
    const expandedClasses = side === "left" ? [...this.expandedSidebarClasses, "border-r"] : [...this.expandedSidebarClasses, "border-l"];
    const collapsedClasses = side === "left" ? [...this.collapsedSidebarClasses, "border-r-0"] : [...this.collapsedSidebarClasses, "border-l-0"];

    if (isCurrentlyOpen) {
      el.classList.remove(...expandedClasses);
      el.classList.add(...collapsedClasses);
      el.inert = true;
    } else {
      el.classList.add(...expandedClasses);
      el.classList.remove(...collapsedClasses);
      el.inert = false;
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
