import { Controller } from "@hotwired/stimulus";

// Handles logo source selection (auto vs manual) via segmented control.
export default class extends Controller {
  static targets = ["input", "segment"];

  select(event) {
    this.setSource(event.params.source);
  }

  // Public so logo-file-controller can call it when a file is selected.
  setSource(source) {
    this.inputTarget.value = source;

    this.segmentTargets.forEach((segment) => {
      const isActive = segment.dataset.logoSourceSourceParam === source;
      // Selected styling is encapsulated in the DS::SegmentedControl active
      // class; keep assistive tech in sync with the visual selection.
      segment.classList.toggle("segmented-control__segment--active", isActive);
      segment.setAttribute("aria-pressed", String(isActive));
    });
  }
}
