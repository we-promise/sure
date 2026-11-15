import { Controller } from "@hotwired/stimulus";

// Shows a transaction's tags as full pills when they all fit on one line,
// otherwise the compact letter-badge pill. The available width comes from the
// closest `[data-tag-fit-bounds]` ancestor (its value is the share of that
// width the tags may use), which is sized by the grid/line rather than by the
// tags, so toggling between the two forms can't feed back into the observer.
export default class extends Controller {
  static targets = ["full", "compact"];

  connect() {
    this.bounds =
      this.element.closest("[data-tag-fit-bounds]") ||
      this.element.parentElement;
    this.resizeObserver = new ResizeObserver(() => this.fit());
    this.resizeObserver.observe(this.bounds);
    this.fit();
  }

  disconnect() {
    this.resizeObserver?.disconnect();
  }

  fit() {
    // Hidden bounds (e.g. the mobile line on desktop) have no width to fit.
    if (this.bounds.clientWidth === 0) return;

    this.showFull(true);
    const pills = this.fullTarget.firstElementChild;
    this.showFull(pills.scrollWidth <= this.availableWidth());
  }

  availableWidth() {
    const style = getComputedStyle(this.bounds);
    const padding =
      Number.parseFloat(style.paddingLeft) +
      Number.parseFloat(style.paddingRight);
    const share = Number.parseFloat(this.bounds.dataset.tagFitBounds) || 1;
    return (this.bounds.clientWidth - padding) * share;
  }

  showFull(full) {
    this.fullTarget.hidden = !full;
    this.compactTarget.hidden = full;
  }
}
