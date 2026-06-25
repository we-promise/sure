import { Controller } from "@hotwired/stimulus";

// Packs variable-height dashboard cards into a tight masonry layout by computing
// each card's grid row span from its measured height, letting `grid-auto-flow:
// dense` fill the gaps. Active only when the grid is actually multi-column; in
// single-column mode it clears the spans and normal block flow takes over.
//
// The DOM stays a single flat list of <section data-section-key> children, so
// the dashboard-sortable controller (drag / keyboard reorder) is unaffected —
// reordering just moves a node and the CSS re-packs.
export default class extends Controller {
  connect() {
    this._scheduleLayout = this._scheduleLayout.bind(this);
    this._frame = null;
    this._resizeObserver = new ResizeObserver(this._scheduleLayout);

    this._cards().forEach((card) => this._resizeObserver.observe(card));
    this._scheduleLayout();

    // Re-pack after the dashboard turbo frame re-renders (period change, reorder
    // save) and on viewport changes that may cross the column breakpoint.
    this.element.addEventListener("turbo:frame-load", this._scheduleLayout);
    window.addEventListener("resize", this._scheduleLayout);
  }

  disconnect() {
    this._resizeObserver?.disconnect();
    this.element.removeEventListener("turbo:frame-load", this._scheduleLayout);
    window.removeEventListener("resize", this._scheduleLayout);
    if (this._frame) cancelAnimationFrame(this._frame);
    this._cards().forEach((card) => {
      card.style.gridRowEnd = "";
      delete card.dataset.masonrySpan;
    });
  }

  _cards() {
    return Array.from(
      this.element.querySelectorAll(":scope > [data-section-key]"),
    );
  }

  _scheduleLayout() {
    if (this._frame) cancelAnimationFrame(this._frame);
    this._frame = requestAnimationFrame(() => this._layout());
  }

  _layout() {
    const styles = getComputedStyle(this.element);
    const columns = styles.gridTemplateColumns
      .split(" ")
      .filter(Boolean).length;

    // Single column: let natural block flow handle it, clear any stale spans.
    if (columns < 2) {
      this._cards().forEach((card) => {
        if (card.dataset.masonrySpan) {
          card.style.gridRowEnd = "";
          delete card.dataset.masonrySpan;
        }
      });
      return;
    }

    // The row gap is zeroed in masonry mode (2xl:gap-y-0). We reproduce a uniform
    // inter-card gap by padding each card's span with empty tracks equal to the
    // column gap. Integer row-spans over a non-zero row gap otherwise overshoot
    // by up to one gap's worth of slack, giving visibly uneven vertical gaps.
    const rowUnit = Number.parseFloat(styles.gridAutoRows) || 1;
    const gap = Number.parseFloat(styles.columnGap) || 0;
    const gapTracks = Math.round(gap / rowUnit);

    this._cards().forEach((card) => {
      const height = card.getBoundingClientRect().height;
      const span = Math.max(1, Math.ceil(height / rowUnit) + gapTracks);
      if (card.dataset.masonrySpan !== String(span)) {
        card.style.gridRowEnd = `span ${span}`;
        card.dataset.masonrySpan = String(span);
      }
    });
  }
}
