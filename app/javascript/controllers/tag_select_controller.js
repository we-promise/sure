import { Controller } from "@hotwired/stimulus";

export default class extends Controller {
  static targets = [
    "button",
    "menu",
    "search",
    "list",
    "option",
    "selectionContainer",
    "createForm",
  ];

  static values = {
    createUrl: String,
    fieldName: String,
    defaultColor: String,
    disabled: Boolean,
    autoSubmit: Boolean,
    updateUrl: String,
  };

  connect() {
    this.isOpen = false;
    this.selectedIds = new Set(
      this.optionTargets
        .filter((option) => option.getAttribute("aria-selected") === "true")
        .map((option) => option.dataset.tagId),
    );
    this.renderSelection();
  }

  disconnect() {
    if (this.submitAbortController) this.submitAbortController.abort();
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

    requestAnimationFrame(() => {
      this.menuTarget.classList.remove(
        "opacity-0",
        "-translate-y-1",
        "pointer-events-none",
      );
      this.menuTarget.classList.add("opacity-100", "translate-y-0");
      this.searchTarget.focus({ preventScroll: true });
    });
  }

  close() {
    this.isOpen = false;
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
  }

  handleSearchKeydown(event) {
    if (
      event.key === "Enter" &&
      !this.createFormTarget.classList.contains("hidden")
    ) {
      event.preventDefault();
      this.createTag();
    }
  }

  async createTag() {
    const name = this.searchTarget.value.trim();
    if (!name) return;

    this.createFormTarget.disabled = true;

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

      if (!response.ok) return;

      const tag = await response.json();
      const option = this.buildOption(tag);
      this.listTarget.insertBefore(option, this.createFormTarget);
      this.selectedIds.add(String(tag.id));
      this.renderSelection();
      this.searchTarget.value = "";
      this.filter();
      this.submitForm();
    } finally {
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
      this.selectionContainerTarget.appendChild(
        this.buildBadge(option.dataset.tagName, option.dataset.tagColor),
      );
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

  buildOption(tag) {
    const option = document.createElement("button");
    option.type = "button";
    option.className =
      "filterable-item text-primary text-sm cursor-pointer flex items-center gap-2 px-3 py-1.5 rounded-lg hover:bg-container-inset-hover";
    option.setAttribute("role", "option");
    option.setAttribute("aria-selected", "true");
    option.dataset.action = "click->tag-select#toggleTag";
    option.dataset.tagSelectTarget = "option";
    option.dataset.tagId = String(tag.id);
    option.dataset.tagName = tag.name;
    option.dataset.tagColor = tag.color;
    option.dataset.filterName = tag.name;

    const checkIcon = this.buildCheckIcon();

    option.appendChild(checkIcon);
    option.appendChild(this.buildBadge(tag.name, tag.color));

    return option;
  }

  buildHiddenInput(id) {
    const input = document.createElement("input");
    input.type = "hidden";
    input.name = this.fieldNameValue;
    input.value = id;
    input.disabled = this.disabledValue;
    return input;
  }

  buildBadge(name, color) {
    const badge = document.createElement("span");
    badge.className =
      "flex items-center gap-2 text-sm font-medium rounded-full px-2.5 py-0.5 border truncate";
    badge.style.backgroundColor = `color-mix(in oklab, ${color} 10%, transparent)`;
    badge.style.borderColor = `color-mix(in oklab, ${color} 20%, transparent)`;
    badge.style.color = color;

    const dot = document.createElement("span");
    dot.className = "size-1.5 rounded-full shrink-0";
    dot.style.backgroundColor = color;

    const label = document.createElement("span");
    label.textContent = name;

    badge.append(dot, label);
    return badge;
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

  buildCheckIcon() {
    const container = document.createElement("span");
    container.className = "check-icon w-5 shrink-0";

    const svg = document.createElementNS("http://www.w3.org/2000/svg", "svg");
    svg.setAttribute("xmlns", "http://www.w3.org/2000/svg");
    svg.setAttribute("width", "20");
    svg.setAttribute("height", "20");
    svg.setAttribute("viewBox", "0 0 24 24");
    svg.setAttribute("fill", "none");
    svg.setAttribute("stroke", "currentColor");
    svg.setAttribute("stroke-width", "2");
    svg.setAttribute("stroke-linecap", "round");
    svg.setAttribute("stroke-linejoin", "round");
    svg.classList.add("lucide", "lucide-check");

    const path = document.createElementNS("http://www.w3.org/2000/svg", "path");
    path.setAttribute("d", "M20 6 9 17l-5-5");

    svg.appendChild(path);
    container.appendChild(svg);

    return container;
  }

  handleKeydown(event) {
    if (event.key === "Escape" && this.isOpen) {
      event.preventDefault();
      this.close();
      this.buttonTarget.focus();
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

  buildPlaceholder() {
    const placeholder = document.createElement("span");
    placeholder.className = "text-secondary";
    placeholder.textContent = this.selectionContainerTarget.dataset.placeholder;
    return placeholder;
  }
}
