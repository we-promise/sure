import { Controller } from "@hotwired/stimulus";

// Basic functionality to filter a list based on a provided text attribute.
export default class extends Controller {
  static targets = ["input", "list", "emptyMessage"];

  connect() {
    this.inputTarget.focus();
    this.highlightedIndex = -1;
    this.updateAriaActiveDescendant();
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

    this.highlightQueryMatches(filterValue);
    this.highlightedIndex = -1;
    this.clearHighlights();
    this.updateAriaActiveDescendant();
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
    return Array.from(this.listTarget.querySelectorAll(".filterable-item")).filter(
      (item) => item.style.display !== "none"
    );
  }

  highlightQueryMatches(filterValue) {
    const highlightTargets = this.listTarget.querySelectorAll("[data-list-filter-highlight]");

    highlightTargets.forEach((target) => {
      if (!target.dataset.originalText) {
        target.dataset.originalText = target.textContent;
      }

      const originalText = target.dataset.originalText;

      if (!filterValue) {
        target.innerHTML = this.escapeHtml(originalText);
        return;
      }

      target.innerHTML = this.buildHighlightedText(originalText, filterValue);
    });
  }

  buildHighlightedText(text, filterValue) {
    const normalizedText = text.toLowerCase();
    let fromIndex = 0;
    let highlightedText = "";
    let matchIndex = normalizedText.indexOf(filterValue, fromIndex);

    while (matchIndex !== -1) {
      const beforeMatch = text.slice(fromIndex, matchIndex);
      const match = text.slice(matchIndex, matchIndex + filterValue.length);

      highlightedText += this.escapeHtml(beforeMatch);
      highlightedText += `<mark class="bg-transparent px-0 text-warning font-medium">${this.escapeHtml(match)}</mark>`;

      fromIndex = matchIndex + filterValue.length;
      matchIndex = normalizedText.indexOf(filterValue, fromIndex);
    }

    highlightedText += this.escapeHtml(text.slice(fromIndex));
    return highlightedText;
  }

  escapeHtml(text) {
    const textNode = document.createTextNode(text);
    const div = document.createElement("div");

    div.appendChild(textNode);
    return div.innerHTML;
  }
}
