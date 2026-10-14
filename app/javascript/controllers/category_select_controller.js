import { Controller } from "@hotwired/stimulus";
import { createCategory } from "utils/category_create";

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
    "list",
    "createAsSubcategory",
    "parentPicker",
    "parentPickerLabel",
    "parentOption",
    "parentOptionTemplate",
    "parentRows",
    "parentBack",
  ];

  static values = {
    createUrl: String,
    defaultColor: String,
    disabled: Boolean,
    autoSubmit: Boolean,
    createLabel: String,
    createErrorMessage: String,
    parentPickerLabel: String,
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
    this.hideParentPicker();

    requestAnimationFrame(() => this.searchTarget.focus());
  }

  close() {
    this.isOpen = false;
    this.buttonTarget.setAttribute("aria-expanded", "false");
    this.menuTarget.classList.add("hidden");
  }

  filter() {
    this.clearCreateError();
    // Editing the name returns to the list, so the picker never shows a stale name.
    this.hideParentPicker();

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

    if (this.hasCreateAsSubcategoryTarget) {
      // Nesting needs at least one top-level category to nest under.
      const canNest = canCreate && this.parentOptionTargets.length > 0;
      this.createAsSubcategoryTarget.classList.toggle("hidden", !canNest);
      this.createAsSubcategoryTarget.classList.toggle("flex", canNest);
    }

    this.createLabelTarget.textContent =
      this.createLabelValue.replace("__CATEGORY_NAME__", rawQuery);
  }

  handleSearchKeydown(event) {
    // With the parent picker open, Enter moves into it instead of creating a
    // top-level category (or submitting the surrounding form).
    if (event.key === "Enter" && this.#parentPickerOpen()) {
      event.preventDefault();
      this.parentOptionTargets[0]?.focus();
      return;
    }

    if (
      event.key === "Enter" &&
      !this.createFormTarget.classList.contains("hidden") &&
      !this.#parentPickerOpen() &&
      !this.creating
    ) {
      event.preventDefault();
      this.createCategory();
    }
  }

  // Escape from anywhere in the menu: leave the parent picker first, then
  // close the menu, keeping focus where the keyboard user can carry on.
  escape(event) {
    event.preventDefault();
    if (this.#parentPickerOpen()) {
      this.hideParentPicker(event);
      return;
    }
    this.close();
    this.buttonTarget.focus();
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

  showParentPicker(event) {
    event?.preventDefault();
    if (!this.hasParentPickerTarget) return;

    const name = this.searchTarget.value.trim();
    if (!name) return;

    this.parentPickerLabelTarget.textContent =
      this.parentPickerLabelValue.replace("__CATEGORY_NAME__", name);

    this.listTarget.classList.add("hidden");
    this.parentPickerTarget.classList.remove("hidden");
    this.parentPickerTarget.classList.add("flex");

    // The button that opened the picker is now hidden; move focus into it.
    this.parentOptionTargets[0]?.focus();
  }

  // From Back or Escape (an event) focus returns to the search; when filter()
  // or open() reset the picker, focus is left alone.
  hideParentPicker(event) {
    event?.preventDefault();
    if (!this.hasParentPickerTarget) return;

    const wasOpen = this.#parentPickerOpen();
    this.parentPickerTarget.classList.add("hidden");
    this.parentPickerTarget.classList.remove("flex");
    this.listTarget.classList.remove("hidden");

    if (event && wasOpen) this.searchTarget.focus();
  }

  createUnderParent(event) {
    event.preventDefault();
    this.#create(event.currentTarget.dataset.parentId);
  }

  createCategory(event) {
    event?.preventDefault();
    this.#create(null);
  }

  async #create(parentId) {
    if (this.creating) return;

    const name = this.searchTarget.value.trim();
    if (!name) return;

    this.creating = true;
    this.#setCreating(true);
    this.clearCreateError();

    try {
      const { category, error } = await createCategory({
        url: this.createUrlValue,
        name,
        color: this.defaultColorValue,
        parentId,
      });

      if (!category) {
        this.hideParentPicker();
        this.showCreateError(error);
        return;
      }

      // A subcategory goes at the end of its parent's group, not the list.
      const anchor = parentId ? this.#lastOptionInGroup(parentId) : null;
      if (anchor) anchor.insertAdjacentHTML("afterend", category.html);
      else this.createFormTarget.insertAdjacentHTML("beforebegin", category.html);

      const newOption = this.optionTargets.find(
        (option) => option.dataset.categoryId === String(category.id),
      );

      if (newOption) this.selectOption(newOption);
      if (!parentId) this.#addParentOption(category, newOption);

      this.searchTarget.value = "";
      this.filter();
      this.close();
      this.submitForm();
    } finally {
      this.creating = false;
      this.#setCreating(false);
    }
  }

  #parentPickerOpen() {
    return (
      this.hasParentPickerTarget &&
      !this.parentPickerTarget.classList.contains("hidden")
    );
  }

  // Disable every way of creating while a request runs, so a slow POST
  // visibly can't be repeated from the picker either.
  #setCreating(creating) {
    this.createFormTarget.disabled = creating;
    for (const row of this.parentOptionTargets) row.disabled = creating;
  }

  #lastOptionInGroup(parentId) {
    let node = this.optionTargets.find(
      (option) => option.dataset.categoryId === String(parentId),
    );
    while (
      node?.nextElementSibling?.querySelector?.(
        "[data-testid=category-select-subcategory-indicator]",
      )
    ) {
      node = node.nextElementSibling;
    }
    return node;
  }

  // A top-level category created inline can be a parent straight away,
  // without reloading: add it to the parent picker in alphabetical order.
  #addParentOption(category, option) {
    if (!this.hasParentOptionTemplateTarget) return;

    const row =
      this.parentOptionTemplateTarget.content.firstElementChild.cloneNode(true);
    row.dataset.parentId = String(category.id);
    row.dataset.parentName = category.name;

    const badge = option?.querySelector("[data-category-select-badge]");
    const slot = row.querySelector("[data-category-select-parent-badge]");
    if (badge && slot) slot.replaceWith(badge.cloneNode(true));

    const name = category.name.toLocaleLowerCase();
    const before = this.parentOptionTargets.find(
      (existing) =>
        (existing.dataset.parentName || "").toLocaleLowerCase() > name,
    );
    this.parentRowsTarget.insertBefore(
      row,
      before || this.parentOptionTemplateTarget,
    );
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
}
