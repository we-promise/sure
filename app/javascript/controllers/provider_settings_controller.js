import { Controller } from "@hotwired/stimulus";

// Drives the LLM provider picker on the self-hosting settings page.
//
// A DS::SegmentedControl selects the active provider: clicking a segment
// reveals that provider's settings panel immediately (no reload flash),
// updates the hidden llm_provider field, and submits the selector form to
// persist the choice. Both panels stay in the DOM so either provider can be
// configured; the inactive one is `hidden`.
export default class extends Controller {
  static targets = ["panel", "segment", "field", "form"];
  static values = { active: String };

  activeValueChanged() {
    this.panelTargets.forEach((panel) => {
      panel.hidden = panel.dataset.provider !== this.activeValue;
    });

    this.segmentTargets.forEach((segment) => {
      const isActive = segment.dataset.provider === this.activeValue;
      segment.classList.toggle(
        "segmented-control__segment--active",
        isActive,
      );
      segment.setAttribute("aria-pressed", isActive.toString());
    });

    if (this.hasFieldTarget) this.fieldTarget.value = this.activeValue;
  }

  select(event) {
    // Works for both the desktop segmented buttons (data-provider) and the
    // mobile <select> fallback (its value).
    const el = event.currentTarget;
    const provider = el.dataset.provider || el.value;
    if (!provider || provider === this.activeValue) return;

    // Set the field explicitly before submitting: `activeValueChanged` runs on
    // a microtask, so relying on it to update the field would race requestSubmit.
    if (this.hasFieldTarget) this.fieldTarget.value = provider;
    this.activeValue = provider;
    if (this.hasFormTarget) this.formTarget.requestSubmit();
  }
}
