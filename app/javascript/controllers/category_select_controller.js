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
    "createLabel",
    "createError",
  ];

  static values = {
    createUrl: String,
    defaultColor: String,
    disabled: Boolean,
    autoSubmit: Boolean,
    createLabel: String,
    createErrorMessage: String,
  };

  connect() {
    this.creating = false;
    this.isOpen = false;
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

    requestAnimationFrame(() => this.searchTarget.focus());
  }

  close() {
    this.isOpen = false;
    this.buttonTarget.setAttribute("aria-expanded", "false");
    this.menuTarget.classList.add("hidden");
  }

  filter() {
    this.clearCreateError();

    const rawQuery = this.searchTarget.value.trim();
    const query = rawQuery.toLowerCase();

    let exactMatch = false;

    this.optionTargets.forEach((option) => {
      const name = option.dataset.categoryName.toLowerCase();
      const matches = name.includes(query);

      option.classList.toggle("hidden", !matches);

      if (name === query) exactMatch = true;
    });

    const canCreate = rawQuery.length > 0 && !exactMatch;

    this.createFormTarget.classList.toggle("hidden", !canCreate);
    this.createFormTarget.classList.toggle("flex", canCreate);

    this.createLabelTarget.textContent =
      this.createLabelValue.replace("__CATEGORY_NAME__", rawQuery);
  }

  handleSearchKeydown(event) {
    if (event.key === "Escape") {
      event.preventDefault();
      this.close();
      this.buttonTarget.focus();
      return;
    }

    if (
      event.key === "Enter" &&
      !this.createFormTarget.classList.contains("hidden") &&
      !this.creating
    ) {
      event.preventDefault();
      this.createCategory();
    }
  }

  selectCategory(event) {
    event.preventDefault();

    const option = event.currentTarget;

    this.selectOption(option);
    this.close();
    this.submitForm();
  }

  selectOption(option) {
    const id = option.dataset.categoryId;

    this.optionTargets.forEach((candidate) => {
      const selected = candidate === option;

      candidate.setAttribute(
        "aria-selected",
        selected ? "true" : "false",
      );

      candidate.classList.toggle("bg-container-inset", selected);

      const checkIcon = candidate.querySelector(".check-icon");
      if (checkIcon) checkIcon.classList.toggle("invisible", !selected);
    });

    this.hiddenInputTarget.value = id;

    const badge = option.querySelector("[data-category-select-badge]");

    this.selectionContainerTarget.innerHTML = "";

    if (badge) {
      this.selectionContainerTarget.appendChild(badge.cloneNode(true));
    } else {
      this.selectionContainerTarget.textContent =
        option.dataset.categoryDisplayLabel;
    }
  }

  async createCategory() {
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
          category: {
            name,
            color: this.defaultColorValue,
          },
        }),
      });

      const category = await response.json();

      if (!response.ok) {
        this.showCreateError(
          category.errors?.join(", ") || category.error,
        );
        return;
      }

      this.createFormTarget.insertAdjacentHTML(
        "beforebegin",
        category.html,
      );

      const newOption = this.optionTargets.find(
        (option) =>
        option.dataset.categoryId === String(category.id),
      );

      if (newOption) this.selectOption(newOption);

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

  async submitForm() {
    if (!this.autoSubmitValue) return;

    const form = this.element.closest("form");
    if (form) form.requestSubmit();
  }

  handleOutsideClick(event) {
    if (this.isOpen && !this.element.contains(event.target)) {
      this.close();
    }
  }

  clearCreateError() {
    this.createErrorTarget.textContent = "";
    this.createErrorTarget.classList.add("hidden");
  }

  showCreateError(message) {
    this.createErrorTarget.textContent =
      message || this.createErrorMessageValue;

    this.createErrorTarget.classList.remove("hidden");
  }

  get csrfToken() {
    return document
      .querySelector('meta[name="csrf-token"]')
      ?.getAttribute("content");
  }
}
