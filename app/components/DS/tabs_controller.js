import { Controller } from "@hotwired/stimulus";

// Connects to data-controller="tabs--components"
export default class extends Controller {
  static classes = ["navBtnActive", "navBtnInactive"];
  static targets = ["panel", "navBtn"];
  static values = { sessionKey: String, urlParamKey: String };

  show(e) {
    const btn = e.target.closest("button");
    const selectedTabId = btn.dataset.id;

    this.navBtnTargets.forEach((navBtn) => {
      const isSelected = navBtn.dataset.id === selectedTabId;
      if (isSelected) {
        navBtn.classList.add(...this.navBtnActiveClasses);
        navBtn.classList.remove(...this.navBtnInactiveClasses);
      } else {
        navBtn.classList.add(...this.navBtnInactiveClasses);
        navBtn.classList.remove(...this.navBtnActiveClasses);
      }
      // Roving tabindex per WAI-ARIA APG: only the active tab is in
      // the tab order. ArrowLeft/Right (see handleKeydown) moves focus
      // across the tablist; Tab moves past the widget.
      navBtn.setAttribute("aria-selected", isSelected.toString());
      navBtn.setAttribute("tabindex", isSelected ? "0" : "-1");
    });

    this.panelTargets.forEach((panel) => {
      if (panel.dataset.id === selectedTabId) {
        panel.classList.remove("hidden");
      } else {
        panel.classList.add("hidden");
      }
    });

    if (this.urlParamKeyValue) {
      const url = new URL(window.location.href);
      url.searchParams.set(this.urlParamKeyValue, selectedTabId);
      window.history.replaceState({}, "", url);
    }

    // Update URL with the selected tab
    if (this.sessionKeyValue) {
      this.#updateSessionPreference(selectedTabId);
    }
  }

  // WAI-ARIA APG "Tabs with Manual Activation" — arrow keys move
  // focus, Enter/Space activates. Prevents accidental tab swap when
  // tabbing through, which is important here because some tab
  // contents trigger Turbo fetches.
  handleKeydown(e) {
    const navBtns = this.navBtnTargets;
    const currentIndex = navBtns.indexOf(e.target);
    if (currentIndex === -1) return;

    let nextIndex = null;
    switch (e.key) {
      case "ArrowRight":
        nextIndex = (currentIndex + 1) % navBtns.length;
        break;
      case "ArrowLeft":
        nextIndex = (currentIndex - 1 + navBtns.length) % navBtns.length;
        break;
      case "Home":
        nextIndex = 0;
        break;
      case "End":
        nextIndex = navBtns.length - 1;
        break;
      case "Enter":
      case " ":
        e.preventDefault();
        this.show(e);
        return;
      default:
        return;
    }

    e.preventDefault();
    navBtns[nextIndex].focus();
  }

  #updateSessionPreference(selectedTabId) {
    fetch("/current_session", {
      method: "PUT",
      headers: {
        "Content-Type": "application/x-www-form-urlencoded",
        "X-CSRF-Token": document.querySelector('[name="csrf-token"]').content,
        Accept: "application/json",
      },
      body: new URLSearchParams({
        "current_session[tab_key]": this.sessionKeyValue,
        "current_session[tab_value]": selectedTabId,
      }).toString(),
    });
  }
}
