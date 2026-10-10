import { Controller } from "@hotwired/stimulus";

export default class extends Controller {
  static targets = ["scroller", "bar"];

  connect() {
    this.resizeObserver = new ResizeObserver(() => {
      if (!this.initialScrollDone && this.scrollerTarget.clientWidth > 0) {
        this.scrollerTarget.scrollLeft = this.scrollerTarget.scrollWidth;
        this.initialScrollDone = true;
      }
    });
    this.resizeObserver.observe(this.scrollerTarget);
    const last = this.barTargets.at(-1);
    if (last) this.showMonth(last);
  }

  disconnect() {
    this.resizeObserver.disconnect();
  }

  select(event) {
    const bar = event.currentTarget;
    this.showMonth(bar);
    const detail = this.details.find(
      (item) => item.dataset.month === bar.dataset.month,
    );
    if (detail) detail.querySelector("summary").focus({ preventScroll: true });
  }

  showMonth(bar) {
    this.barTargets.forEach((item) => {
      const selected = item === bar;
      item.setAttribute("aria-pressed", String(selected));
      item.classList.toggle("bg-container-inset-hover", selected);
    });
    for (const detail of this.details) {
      const selected = detail.dataset.month === bar.dataset.month;
      detail.hidden = !selected;
      detail.classList.toggle("hidden", !selected);
      detail.open = selected;
    }
  }

  get details() {
    return Array.from(
      this.element
        .closest("#monthly-spending-section")
        .querySelectorAll("details[data-month]"),
    );
  }
}
