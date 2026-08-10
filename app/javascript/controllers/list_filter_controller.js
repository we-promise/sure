import { Controller } from "@hotwired/stimulus";

// Basic functionality to filter a list based on a provided text attribute.
export default class extends Controller {
  static targets = [
    "input",
    "list",
    "emptyMessage",
    "recentSection",
    "addItem",
    "addText",
    "addLabel",
  ];

  connect() {
    this.inputTarget.focus();
    this.highlightedIndex = -1;
    this.updateAriaActiveDescendant();
  }

  filter() {
    const rawFilterValue = this.inputTarget.value;
    const categoryName = rawFilterValue.trim();
    const filterValue = this.normalize(categoryName);
    const hasSearch = categoryName.length > 0;
    const items = this.listTarget.querySelectorAll(".filterable-item");
    let noMatchFound = true;

    if (this.hasRecentSectionTarget) {
      this.recentSectionTarget.classList.toggle("hidden", hasSearch);
    }

    if (this.hasEmptyMessageTarget) {
      this.emptyMessageTarget.classList.add("hidden");
    }

    items.forEach((item) => {
      const text = this.normalize(item.getAttribute("data-filter-name"));
      const shouldDisplay =
        !hasSearch || (filterValue.length > 0 && text.includes(filterValue));
      item.style.display = shouldDisplay ? "" : "none";

      if (shouldDisplay) {
        noMatchFound = false;
      }
    });

    if (noMatchFound && this.hasEmptyMessageTarget) {
      this.emptyMessageTarget.classList.remove("hidden");
    }

    this.updateAddCategory(rawFilterValue, noMatchFound);

    this.highlightedIndex = -1;
    this.clearHighlights();
    this.updateAriaActiveDescendant();
  }

  // Case- and diacritic-insensitive: "prestecs" should match "Prèstecs".
  // NFD splits each accented char into base char + combining mark, then
  // \p{Mark} strips the marks, so both sides compare on bare base characters.
  // Not \p{Diacritic}: that property is broader than combining marks — it
  // also covers standalone characters like "^", "`", the middot, and
  // modifier letters (e.g. the Hawaiian ʻokina) — so a query of just one of
  // those would normalize to "", and "".includes() matches everything,
  // silently showing every row instead of filtering.
  normalize(value) {
    return value
      .normalize("NFD")
      .replace(/\p{Mark}/gu, "")
      .toLowerCase();
  }

  handleKeydown(event) {
    if (event.key === "ArrowDown") {
      event.preventDefault();
      this.highlightNext();
    } else if (event.key === "ArrowUp") {
      event.preventDefault();
      this.highlightPrevious();
    } else if (event.key === "Enter") {
      event.preventDefault();
      this.selectHighlighted();
    }
  }

  highlightNext() {
    const items = this.visibleItems;
    if (items.length === 0) return;

    this.clearHighlights();
    this.highlightedIndex = Math.min(
      this.highlightedIndex + 1,
      items.length - 1,
    );
    this.highlightItem(items[this.highlightedIndex]);
    this.updateAriaActiveDescendant();
  }

  highlightPrevious() {
    const items = this.visibleItems;
    if (items.length === 0) return;

    this.clearHighlights();
    this.highlightedIndex = Math.max(this.highlightedIndex - 1, 0);
    this.highlightItem(items[this.highlightedIndex]);
    this.updateAriaActiveDescendant();
  }

  highlightItem(item) {
    item.classList.add("bg-container-inset-hover");
    item.setAttribute("aria-selected", "true");
    item.scrollIntoView({ block: "nearest" });
  }

  clearHighlights() {
    this.listTarget.querySelectorAll(".filterable-item").forEach((item) => {
      item.classList.remove("bg-container-inset-hover");
      item.setAttribute("aria-selected", "false");
    });

    if (this.hasAddItemTarget) {
      this.addItemTarget.classList.remove("bg-container-inset-hover");
      this.addItemTarget.setAttribute("aria-selected", "false");
    }
  }

  selectHighlighted() {
    const items = this.visibleItems;
    if (this.highlightedIndex < 0 || this.highlightedIndex >= items.length)
      return;

    const item = items[this.highlightedIndex];
    if (this.hasAddItemTarget && item === this.addItemTarget) {
      item.click();
      return;
    }

    const form = item.querySelector("form");
    if (form) {
      form.requestSubmit();
    }
  }

  updateAriaActiveDescendant() {
    const items = this.visibleItems;
    if (this.highlightedIndex >= 0 && this.highlightedIndex < items.length) {
      const item = items[this.highlightedIndex];
      this.inputTarget.setAttribute("aria-activedescendant", item.id);
    } else {
      this.inputTarget.removeAttribute("aria-activedescendant");
    }
  }

  get visibleItems() {
    const items = Array.from(this.listTarget.querySelectorAll(".filterable-item")).filter((item) => {
      if (item.style.display === "none") return false;
      return !(
        this.hasRecentSectionTarget &&
        this.recentSectionTarget.classList.contains("hidden") &&
        this.recentSectionTarget.contains(item)
      );
    });

    if (
      this.hasAddItemTarget &&
      this.addItemTarget.style.display !== "none" &&
      !this.addItemTarget.classList.contains("hidden")
    ) {
      items.unshift(this.addItemTarget);
    }

    return items;
  }

  updateAddCategory(rawFilterValue, noMatchFound) {
    if (!this.hasAddItemTarget) return;

    const categoryName = rawFilterValue.trim();
    const shouldShow = noMatchFound && categoryName.length > 0;
    this.addItemTarget.classList.toggle("hidden", !shouldShow);

    if (this.hasAddLabelTarget) {
      this.addLabelTarget.textContent = this.addLabelTarget.dataset.listFilterAddTemplate.replace(
        "%{name}",
        categoryName
      );
    } else if (this.hasAddTextTarget) {
      this.addTextTarget.textContent = categoryName;
    }

    if (shouldShow) {
      const url = new URL(this.addItemTarget.dataset.listFilterAddUrl, window.location.origin);
      url.searchParams.set("name", categoryName);
      this.addItemTarget.href = url.toString();
    }

    if (this.hasEmptyMessageTarget) {
      this.emptyMessageTarget.classList.toggle("hidden", !noMatchFound || shouldShow);
    }
  }
}
