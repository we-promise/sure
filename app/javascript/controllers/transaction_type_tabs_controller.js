import { Controller } from "@hotwired/stimulus";

// Expense / income tabs render as a DS::SegmentedControl. Switching is
// client-side here: it updates the form's hidden nature field and flips the
// active segment without navigating (the href is a progressive-enhancement
// fallback). Transfer is a plain link to the transfer form.
//
// The refund toggle and its optional purchase picker are income-only, so the
// same switch also reveals/hides them and clears the toggle when leaving
// income rather than submitting a refund with an outflow.
export default class extends Controller {
  static targets = [
    "tab",
    "natureField",
    "inflowOnly",
    "refundFields",
    "refundToggle",
  ];

  connect() {
    this.toggleRefundFields();
  }

  selectTab(event) {
    event.preventDefault();

    const selectedTab = event.currentTarget;
    this.natureFieldTarget.value = selectedTab.dataset.nature;

    this.tabTargets.forEach((tab) => {
      const isActive = tab === selectedTab;
      tab.classList.toggle("segmented-control__segment--active", isActive);
      if (isActive) {
        tab.setAttribute("aria-current", "true");
      } else {
        tab.removeAttribute("aria-current");
      }
    });

    const isIncome = selectedTab.dataset.nature === "inflow";
    this.inflowOnlyTargets.forEach((element) =>
      element.classList.toggle("hidden", !isIncome),
    );

    if (!isIncome && this.hasRefundToggleTarget) {
      this.refundToggleTarget.checked = false;
    }

    this.toggleRefundFields();
  }

  toggleRefundFields() {
    const isRefund =
      this.hasRefundToggleTarget && this.refundToggleTarget.checked;
    this.refundFieldsTargets.forEach((element) =>
      element.classList.toggle("hidden", !isRefund),
    );
  }
}
