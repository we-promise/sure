import { Controller } from "@hotwired/stimulus";

// Expense / income tabs render as a DS::SegmentedControl. Switching is
// client-side here: it updates the form's hidden nature field and flips the
// active segment without navigating (the href is a progressive-enhancement
// fallback). Transfer is a plain link to the transfer form.
export default class extends Controller {
  static targets = ["tab", "natureField"];

  selectTab(event) {
    event.preventDefault();

    const selectedTab = event.currentTarget;
    this.natureFieldTarget.value = selectedTab.dataset.nature;

    // Broadcast the change so sibling controllers (e.g. transaction-form) can
    // react — keep the event generic so it stays reusable.
    this.dispatch("change", { detail: { nature: selectedTab.dataset.nature } });

    this.tabTargets.forEach((tab) => {
      const isActive = tab === selectedTab;
      tab.classList.toggle("segmented-control__segment--active", isActive);
      if (isActive) {
        tab.setAttribute("aria-current", "true");
      } else {
        tab.removeAttribute("aria-current");
      }
    });
  }
}
