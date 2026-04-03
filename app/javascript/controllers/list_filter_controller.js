import { Controller } from "@hotwired/stimulus";

// Basic functionality to filter a list based on a provided text attribute.
export default class extends Controller {
  static targets = ["input", "list", "emptyMessage"];

  connect() {
    this.inputTarget.focus();
    this.highlightedIndex = -1;
  }

  filter() {
    const filterValue = this.inputTarget.value.toLowerCase();
    const items = this.listTarget.querySelectorAll(".filterable-item");
    let noMatchFound = true;

    if (this.hasEmptyMessageTarget) {
      this.emptyMessageTarget.classList.add("hidden");
    }

    items.forEach((item) => {
      const text = item.getAttribute("data-filter-name").toLowerCase();
      const shouldDisplay = text.includes(filterValue);
      item.style.display = shouldDisplay ? "" : "none";

      if (shouldDisplay) {
        noMatchFound = false;
      }
    });

    if (noMatchFound && this.hasEmptyMessageTarget) {
      this.emptyMessageTarget.classList.remove("hidden");
    }

    this.highlightedIndex = -1;
    this.clearHighlights();
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
    this.highlightedIndex = Math.min(this.highlightedIndex + 1, items.length - 1);
    this.highlightItem(items[this.highlightedIndex]);
  }

  highlightPrevious() {
    const items = this.visibleItems;
    if (items.length === 0) return;

    this.clearHighlights();
    this.highlightedIndex = Math.max(this.highlightedIndex - 1, 0);
    this.highlightItem(items[this.highlightedIndex]);
  }

  highlightItem(item) {
    item.classList.add("bg-container-inset-hover");
    item.scrollIntoView({ block: "nearest" });
  }

  clearHighlights() {
    this.listTarget.querySelectorAll(".filterable-item").forEach((item) => {
      item.classList.remove("bg-container-inset-hover");
    });
  }

  selectHighlighted() {
    const items = this.visibleItems;
    if (this.highlightedIndex < 0 || this.highlightedIndex >= items.length) return;

    const item = items[this.highlightedIndex];
    const form = item.querySelector("form");
    if (form) {
      form.requestSubmit();
    }
  }

  get visibleItems() {
    return Array.from(this.listTarget.querySelectorAll(".filterable-item")).filter(
      (item) => item.style.display !== "none"
    );
  }
}
