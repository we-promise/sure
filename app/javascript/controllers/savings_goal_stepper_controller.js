import { Controller } from "@hotwired/stimulus";

// 2-step modal stepper for creating a savings goal.
//
// Single <form> with two panels. Step 1 collects identity (name, amount,
// date, color, notes). Step 2 collects ≥1 linked depository accounts and
// optionally an initial contribution. Submit button stays disabled until at
// least one linked account is selected. Step state lives entirely in the
// DOM — no half-records.
export default class extends Controller {
  static targets = [
    "step1Panel",
    "step2Panel",
    "step1Indicator",
    "step2Indicator",
    "step1Field",
    "nameField",
    "targetAmountField",
    "linkedAccountCheckbox",
    "initialContributionAmount",
    "initialContributionAccountSelect",
    "reviewPanel",
    "reviewName",
    "reviewAmount",
    "reviewDate",
    "reviewAccounts",
    "submitButton",
  ];

  next(event) {
    event?.preventDefault?.();
    if (!this.validateStep1()) return;

    this.step1PanelTarget.classList.add("hidden");
    this.step2PanelTarget.classList.remove("hidden");
    this.markStepActive(2);
    this.updateReview();
    this.refreshSubmitState();
  }

  back(event) {
    event?.preventDefault?.();
    this.step2PanelTarget.classList.add("hidden");
    this.step1PanelTarget.classList.remove("hidden");
    this.markStepActive(1);
  }

  linkedAccountChanged() {
    this.refreshAccountSelect();
    this.refreshSubmitState();
    this.updateReview();
  }

  validateStep1() {
    let ok = true;
    this.step1FieldTargets.forEach((field) => {
      if (!field.checkValidity()) {
        field.reportValidity();
        ok = false;
      }
    });
    return ok;
  }

  refreshSubmitState() {
    const anyChecked = this.linkedAccountCheckboxTargets.some((cb) => cb.checked);
    this.submitButtonTarget.disabled = !anyChecked;
  }

  refreshAccountSelect() {
    if (!this.hasInitialContributionAccountSelectTarget) return;

    const select = this.initialContributionAccountSelectTarget;
    const previous = select.value;
    select.innerHTML = "";
    const blank = document.createElement("option");
    blank.value = "";
    blank.textContent = select.dataset.blankLabel || "—";
    select.appendChild(blank);

    this.linkedAccountCheckboxTargets
      .filter((cb) => cb.checked)
      .forEach((cb) => {
        const opt = document.createElement("option");
        opt.value = cb.value;
        opt.textContent = cb.dataset.accountName || cb.value;
        select.appendChild(opt);
      });

    if ([...select.options].some((o) => o.value === previous)) {
      select.value = previous;
    }
  }

  updateReview() {
    if (!this.hasReviewPanelTarget) return;

    if (this.hasReviewNameTarget && this.hasNameFieldTarget) {
      this.reviewNameTarget.textContent = this.nameFieldTarget.value || "—";
    }
    if (this.hasReviewAmountTarget && this.hasTargetAmountFieldTarget) {
      this.reviewAmountTarget.textContent = this.targetAmountFieldTarget.value || "—";
    }
    if (this.hasReviewDateTarget) {
      const dateInput = this.element.querySelector('input[type="date"][name="savings_goal[target_date]"]');
      this.reviewDateTarget.textContent = dateInput?.value || "—";
    }
    if (this.hasReviewAccountsTarget) {
      const names = this.linkedAccountCheckboxTargets
        .filter((cb) => cb.checked)
        .map((cb) => cb.dataset.accountName || cb.value);
      this.reviewAccountsTarget.textContent = names.length ? names.join(", ") : "—";
    }
  }

  markStepActive(stepNumber) {
    if (this.hasStep1IndicatorTarget) {
      this.step1IndicatorTarget.classList.toggle("text-primary", stepNumber === 1);
    }
    if (this.hasStep2IndicatorTarget) {
      this.step2IndicatorTarget.classList.toggle("text-primary", stepNumber === 2);
    }
  }
}
