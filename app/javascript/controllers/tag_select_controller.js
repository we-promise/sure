import { autoUpdate } from "@floating-ui/dom";
import { Controller } from "@hotwired/stimulus";

export default class extends Controller {
  static targets = [
    "button",
    "menu",
    "search",
    "option",
    "selectionContainer",
    "createForm",
    "createError",
  ];

  static values = {
    createUrl: String,
    fieldName: String,
    defaultColor: String,
    disabled: Boolean,
    autoSubmit: Boolean,
    updateUrl: String,
    menuPlacement: { type: String, default: "auto" },
    offset: { type: Number, default: 6 },
  };

  connect() {
    this.creating = false;
    this.isOpen = false;
    this.selectedIds = new Set(
      this.optionTargets
        .filter((option) => option.getAttribute("aria-selected") === "true")
        .map((option) => option.dataset.tagId),
    );
    this.renderSelection();
    this.observeMenuResize();
  }

  disconnect() {
    if (this.submitAbortController) this.submitAbortController.abort();
    this.stopAutoUpdate();
    if (this.resizeObserver) this.resizeObserver.disconnect();
  }

  toggle(event) {
    event.preventDefault();
    if (this.disabledValue) return;

    this.isOpen ? this.close() : this.open();
  }

  open(focusOption = false) {
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
      if (focusOption) {
        this.focusActiveOption();
      }
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

  toggleTag(event) {
    event.preventDefault();
    const option = event.currentTarget;
    const id = option.dataset.tagId;

    if (this.selectedIds.has(id)) {
      this.selectedIds.delete(id);
    } else {
      this.selectedIds.add(id);
    }

    this.updateOption(option);
    this.renderSelection();
    this.submitForm();
  }

  filter() {
    this.clearCreateError();

    const query = this.searchTarget.value.trim().toLowerCase();
    let hasExactMatch = false;

    this.optionTargets.forEach((option) => {
      const name = option.dataset.tagName.toLowerCase();
      const isMatch = name.includes(query);
      option.classList.toggle("hidden", !isMatch);

      if (name === query) hasExactMatch = true;
    });

    const canCreate = query.length > 0 && !hasExactMatch;
    this.createFormTarget.classList.toggle("hidden", !canCreate);
    this.createFormTarget.classList.toggle("flex", canCreate);
    this.createNameElement.textContent = this.searchTarget.value.trim();
    this.syncActiveOption();
  }

  handleSearchKeydown(event) {
    if (
      event.key === "Enter" &&
      !this.createFormTarget.classList.contains("hidden") &&
      !this.creating
    ) {
      event.preventDefault();
      this.createTag();
    }
  }

  async createTag() {
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
          tag: {
            name,
            color: this.defaultColorValue,
          },
        }),
      });

      const tag = await this.parseJson(response);

      if (!response.ok) {
        this.showCreateError(tag.errors?.join(", ") || tag.error);
        return;
      }

      this.createFormTarget.insertAdjacentHTML("beforebegin", tag.html);
      this.selectedIds.add(String(tag.id));
      this.renderSelection();
      this.searchTarget.value = "";
      this.filter();
      this.submitForm();
    } finally {
      this.creating = false;
      this.createFormTarget.disabled = false;
    }
  }

  renderSelection() {
    this.hiddenInputsElement.innerHTML = "";
    this.hiddenInputsElement.appendChild(this.buildHiddenInput(""));
    this.selectionContainerTarget.innerHTML = "";

    const selectedOptions = this.optionTargets.filter((option) =>
      this.selectedIds.has(option.dataset.tagId),
    );

    selectedOptions.forEach((option) => {
      this.hiddenInputsElement.appendChild(
        this.buildHiddenInput(option.dataset.tagId),
      );
      const badge = option.querySelector("[data-tag-select-badge]");
      if (badge) {
        this.selectionContainerTarget.appendChild(badge.cloneNode(true));
      }
      this.updateOption(option);
    });

    if (selectedOptions.length === 0) {
      this.selectionContainerTarget.appendChild(this.buildPlaceholder());
    }
  }

  updateOption(option) {
    const isSelected = this.selectedIds.has(option.dataset.tagId);
    option.setAttribute("aria-selected", isSelected ? "true" : "false");
    option.classList.toggle("bg-container-inset", isSelected);

    const icon = option.querySelector(".check-icon");
    if (icon) icon.classList.toggle("hidden", !isSelected);
  }

  buildHiddenInput(id) {
    const input = document.createElement("input");
    input.type = "hidden";
    input.name = this.fieldNameValue;
    input.value = id;
    input.disabled = this.disabledValue;
    return input;
  }

  handleOutsideClick(event) {
    if (this.isOpen && !this.element.contains(event.target)) this.close();
  }

  async submitForm() {
    if (!this.autoSubmitValue) return;
    if (!this.hasUpdateUrlValue || !this.updateUrlValue) return;

    if (this.submitAbortController) this.submitAbortController.abort();

    const abortController = new AbortController();
    this.submitAbortController = abortController;

    try {
      await fetch(this.updateUrlValue, {
        method: "PATCH",
        headers: {
          Accept: "application/json",
          "Content-Type": "application/json",
          "X-CSRF-Token": this.csrfToken,
          "X-Requested-With": "XMLHttpRequest",
        },
        body: JSON.stringify({
          tag_ids: Array.from(this.selectedIds),
        }),
        credentials: "same-origin",
        signal: abortController.signal,
      });
    } catch (error) {
      if (error.name !== "AbortError") throw error;
    } finally {
      if (this.submitAbortController === abortController) {
        this.submitAbortController = null;
      }
    }
  }

  handleKeydown(event) {
    if (!this.isOpen && event.target === this.buttonTarget) {
      if (event.key === "ArrowDown" || event.key === "ArrowUp") {
        event.preventDefault();
        this.open(true);
      }
      return;
    }

    if (!this.isOpen) return;

    if (event.key === "Escape" && this.isOpen) {
      event.preventDefault();
      this.close();
      this.buttonTarget.focus();
      return;
    }

    if (event.key === "ArrowDown") {
      event.preventDefault();
      this.moveActiveOption(1);
      return;
    }

    if (event.key === "ArrowUp") {
      event.preventDefault();
      this.moveActiveOption(-1);
      return;
    }

    if (event.key === "Home") {
      event.preventDefault();
      this.focusOption(this.visibleOptions[0]);
      return;
    }

    if (event.key === "End") {
      event.preventDefault();
      this.focusOption(this.visibleOptions.at(-1));
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

  syncActiveOption() {
    const options = this.visibleOptions;
    const current = this.activeOption;
    const selected = options.find((option) =>
      this.selectedIds.has(option.dataset.tagId),
    );

    this.setActiveOption(
      options.includes(current) ? current : selected || options[0],
      false,
    );
  }

  moveActiveOption(delta) {
    const options = this.visibleOptions;
    if (options.length === 0) return;

    const currentIndex = options.indexOf(this.activeOption);
    const nextIndex =
      currentIndex === -1
        ? delta > 0
          ? 0
          : options.length - 1
        : (currentIndex + delta + options.length) % options.length;

    this.focusOption(options[nextIndex]);
  }

  focusActiveOption() {
    this.focusOption(this.activeOption || this.visibleOptions[0]);
  }

  focusOption(option) {
    this.setActiveOption(option, true);
  }

  setActiveOption(option, focus) {
    this.optionTargets.forEach((target) => {
      target.tabIndex = target === option ? 0 : -1;
    });

    if (!option) return;

    if (focus) {
      option.focus({ preventScroll: true });
      option.scrollIntoView({ block: "nearest" });
    }
  }

  get activeOption() {
    return this.optionTargets.find((option) => option.tabIndex === 0);
  }

  get visibleOptions() {
    return this.optionTargets.filter(
      (option) => !option.classList.contains("hidden"),
    );
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

  get hiddenInputsElement() {
    return this.element.querySelector("[data-tag-select-hidden-inputs]");
  }

  get createNameElement() {
    return this.createFormTarget.querySelector("[data-tag-select-create-name]");
  }

  showCreateError(message) {
    if (!this.hasCreateErrorTarget) return;

    this.createErrorTarget.textContent = message || "Could not create tag";
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

  buildPlaceholder() {
    const placeholder = document.createElement("span");
    placeholder.className = "text-secondary";
    placeholder.textContent = this.selectionContainerTarget.dataset.placeholder;
    return placeholder;
  }
}
