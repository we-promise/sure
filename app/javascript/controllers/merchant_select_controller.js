import { autoUpdate } from "@floating-ui/dom";
import { Controller } from "@hotwired/stimulus";

export default class extends Controller {
  static targets = [
    "button",
    "menu",
    "search",
    "option",
    "selectionContainer",
    "hiddenInput",
    "createForm",
    "createError",
    "listbox",
  ];

  static values = {
    createUrl: String,
    fieldName: String,
    disabled: Boolean,
    autoSubmit: Boolean,
    menuPlacement: { type: String, default: "auto" },
    offset: { type: Number, default: 6 },
    errorMessage: String,
  };

  connect() {
    this.creating = false;
    this.isOpen = false;
    this.selectedId = this.hiddenInputTarget.value || "";
    if (this.disabledValue || !this.hasMenuTarget) return;
    this.observeMenuResize();
  }

  disconnect() {
    this.stopAutoUpdate();
    if (this.resizeObserver) this.resizeObserver.disconnect();
  }

  toggle(event) {
    event.preventDefault();
    if (this.disabledValue) return;

    this.isOpen ? this.close() : this.open();
  }

  open() {
    this.isOpen = true;
    this.buttonTarget.setAttribute("aria-expanded", "true");
    this.menuTarget.classList.remove("hidden");
    this.searchTarget.value = "";
    this.filter();
    this.startAutoUpdate();

    requestAnimationFrame(() => {
      this.menuTarget.classList.remove(
        "opacity-0",
        "-translate-y-1",
        "pointer-events-none",
      );
      this.menuTarget.classList.add("opacity-100", "translate-y-0");
      this.updatePosition();
      this.searchTarget.focus({ preventScroll: true });
    });
  }

  close() {
    this.isOpen = false;
    this.stopAutoUpdate();
    this.buttonTarget.setAttribute("aria-expanded", "false");
    this.menuTarget.classList.remove("opacity-100", "translate-y-0");
    this.menuTarget.classList.add(
      "opacity-0",
      "-translate-y-1",
      "pointer-events-none",
    );

    setTimeout(() => {
      if (!this.isOpen) this.menuTarget.classList.add("hidden");
    }, 150);
  }

  selectOption(event) {
    event.preventDefault();
    this.applySelection(event.currentTarget);
    this.close();
    this.buttonTarget.focus({ preventScroll: true });
    this.submitForm();
  }

  applySelection(option) {
    const id = option.dataset.merchantId || "";

    this.selectedId = id;
    this.hiddenInputTarget.value = id;
    this.hiddenInputTarget.dispatchEvent(new Event("change", { bubbles: true }));

    this.optionTargets.forEach((target) => this.updateOptionState(target, id));
    this.updateSelectionDisplay(option);
  }

  updateOptionState(option, selectedId) {
    const isSelected = (option.dataset.merchantId || "") === selectedId;
    option.setAttribute("aria-selected", isSelected ? "true" : "false");
    option.classList.toggle("bg-container-inset", isSelected);

    const icon = option.querySelector(".check-icon");
    if (icon) icon.classList.toggle("hidden", !isSelected);
  }

  updateSelectionDisplay(option) {
    this.selectionContainerTarget.innerHTML = "";

    Array.from(option.children).forEach((child) => {
      if (child.classList.contains("check-icon")) return;
      this.selectionContainerTarget.appendChild(child.cloneNode(true));
    });
  }

  filter() {
    this.clearCreateError();

    const query = this.searchTarget.value.trim().toLowerCase();
    let hasExactMatch = false;

    this.optionTargets.forEach((option) => {
      const name = (option.dataset.filterName || "").toLowerCase();
      const isMatch = name.includes(query);
      option.classList.toggle("hidden", !isMatch);

      if (name === query) hasExactMatch = true;
    });

    const canCreate = query.length > 0 && !hasExactMatch;
    this.createFormTarget.classList.toggle("hidden", !canCreate);
    this.createFormTarget.classList.toggle("flex", canCreate);
    this.createNameElement.textContent = this.searchTarget.value.trim();
  }

  handleSearchKeydown(event) {
    if (event.key !== "Enter") return;

    if (!this.createFormTarget.classList.contains("hidden") && !this.creating) {
      event.preventDefault();
      this.createMerchant();
      return;
    }

    event.preventDefault();

    const query = this.searchTarget.value.trim().toLowerCase();
    const match = this.optionTargets.find(
      (option) =>
        !option.classList.contains("hidden") &&
        (option.dataset.filterName || "").toLowerCase() === query,
    );

    if (match) {
      this.applySelection(match);
      this.close();
      this.submitForm();
    }
  }

  async createMerchant() {
    if (this.creating) return;

    const name = this.searchTarget.value.trim();
    if (!name) return;

    this.creating = true;
    this.createFormTarget.disabled = true;
    this.clearCreateError();

    try {
      const response = await fetch(this.createUrlValue, {
        method: "POST",
        headers: {
          Accept: "application/json",
          "Content-Type": "application/json",
          "X-CSRF-Token": this.csrfToken,
        },
        body: JSON.stringify({
          family_merchant: { name },
        }),
      });

      const merchant = await this.parseJson(response);

      if (!response.ok) {
        this.showCreateError(merchant.errors?.join(", ") || merchant.error);
        return;
      }

      this.listboxTarget.insertAdjacentHTML("beforeend", merchant.html);
      const newOption = this.listboxTarget.lastElementChild;
      this.applySelection(newOption);
      this.searchTarget.value = "";
      this.filter();
      this.close();
      this.submitForm();
    } catch {
      this.showCreateError();
    } finally {
      this.creating = false;
      this.createFormTarget.disabled = false;
    }
  }

  handleOutsideClick(event) {
    if (this.isOpen && !this.element.contains(event.target)) this.close();
  }

  handleKeydown(event) {
    if (!this.isOpen) return;

    if (event.key === "Escape") {
      event.preventDefault();
      this.close();
      this.buttonTarget.focus();
      return;
    }

    if (event.key === "ArrowDown" || event.key === "ArrowUp") {
      event.preventDefault();
      this.moveActiveOption(event.key === "ArrowDown" ? 1 : -1);
      return;
    }

    if (
      event.key === "Enter" &&
      event.target.getAttribute("role") === "option"
    ) {
      event.preventDefault();
      event.target.click();
    }
  }

  moveActiveOption(delta) {
    const options = this.visibleOptions;
    if (options.length === 0) return;

    const currentIndex = options.indexOf(document.activeElement);
    const nextIndex =
      currentIndex === -1
        ? delta > 0
          ? 0
          : options.length - 1
        : (currentIndex + delta + options.length) % options.length;

    options[nextIndex].focus({ preventScroll: true });
    options[nextIndex].scrollIntoView({ block: "nearest" });
  }

  get visibleOptions() {
    return this.optionTargets.filter(
      (option) => !option.classList.contains("hidden"),
    );
  }

  async submitForm() {
    if (!this.autoSubmitValue) return;

    const form = this.element.closest("form");
    const controllers = (form?.dataset.controller || "").split(/\s+/);
    if (form && controllers.includes("auto-submit-form")) {
      form.requestSubmit();
    }
  }

  startAutoUpdate() {
    if (!this._cleanup && this.hasButtonTarget && this.hasMenuTarget) {
      this._cleanup = autoUpdate(this.buttonTarget, this.menuTarget, () =>
        this.updatePosition(),
      );
    }
  }

  stopAutoUpdate() {
    if (!this._cleanup) return;

    this._cleanup();
    this._cleanup = null;
  }

  observeMenuResize() {
    this.resizeObserver = new ResizeObserver(() => {
      if (this.isOpen) requestAnimationFrame(() => this.updatePosition());
    });
    this.resizeObserver.observe(this.menuTarget);
  }

  getScrollParent(element) {
    let parent = element.parentElement;
    while (parent) {
      const style = getComputedStyle(parent);
      const overflowY = style.overflowY;
      if (overflowY === "auto" || overflowY === "scroll") return parent;
      parent = parent.parentElement;
    }
    return document.documentElement;
  }

  placementMode() {
    const mode = (this.menuPlacementValue || "auto").toLowerCase();
    return ["auto", "down", "up"].includes(mode) ? mode : "auto";
  }

  updatePosition() {
    if (!this.hasButtonTarget || !this.hasMenuTarget || !this.isOpen) return;

    const container = this.getScrollParent(this.element);
    const containerRect = container.getBoundingClientRect();
    const buttonRect = this.buttonTarget.getBoundingClientRect();
    const menuHeight = this.menuTarget.scrollHeight;

    const spaceBelow = containerRect.bottom - buttonRect.bottom;
    const spaceAbove = buttonRect.top - containerRect.top;
    const placement = this.placementMode();
    const shouldOpenUp =
      placement === "up" ||
      (placement === "auto" &&
        spaceBelow < menuHeight &&
        spaceAbove > spaceBelow);

    this.menuTarget.style.left = "0";
    this.menuTarget.style.width = "100%";
    this.menuTarget.style.top = "";
    this.menuTarget.style.bottom = "";
    this.menuTarget.style.overflowY = "auto";

    if (shouldOpenUp) {
      this.menuTarget.style.bottom = "100%";
      this.menuTarget.style.maxHeight = `${Math.max(0, spaceAbove - this.offsetValue)}px`;
    } else {
      this.menuTarget.style.top = "100%";
      this.menuTarget.style.maxHeight = `${Math.max(0, spaceBelow - this.offsetValue)}px`;
    }
  }

  get csrfToken() {
    return document.querySelector("meta[name='csrf-token']")?.content;
  }

  get createNameElement() {
    return this.createFormTarget.querySelector(
      "[data-merchant-select-create-name]",
    );
  }

  showCreateError(message) {
    if (!this.hasCreateErrorTarget) return;

    this.createErrorTarget.textContent = message || this.errorMessageValue;
    this.createErrorTarget.classList.remove("hidden");
    this.searchTarget.setAttribute("aria-invalid", "true");
    this.searchTarget.focus({ preventScroll: true });
  }

  async parseJson(response) {
    try {
      return await response.json();
    } catch {
      return {};
    }
  }

  clearCreateError() {
    if (!this.hasCreateErrorTarget) return;

    this.createErrorTarget.textContent = "";
    this.createErrorTarget.classList.add("hidden");
    this.searchTarget.removeAttribute("aria-invalid");
  }
}
