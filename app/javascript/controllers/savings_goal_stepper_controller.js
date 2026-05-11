import { Controller } from "@hotwired/stimulus";

// 2-step modal stepper for creating a savings goal.
//
// Single <form> with two panels. Step 1 collects identity (name, amount,
// date, color, notes, linked accounts). Step 2 reviews + optional initial
// contribution. All state lives in the DOM — no half-records, single POST.
export default class extends Controller {
  static targets = [
    "step1Panel",
    "step2Panel",
    "step1Indicator",
    "step2Indicator",
    "step1Circle",
    "step2Circle",
    "stepperLine",
    "modalSubtitle",
    "nameInput",
    "amountInput",
    "avatarPreview",
    "nameError",
    "amountError",
    "accountsError",
    "linkedAccountCheckbox",
    "initialContributionAmount",
    "initialContributionAccountSelect",
    "reviewName",
    "reviewSummary",
    "reviewAccounts",
    "reviewSuggested",
    "footerLeftButton",
    "footerRightButton",
    "submitButton",
  ];

  static INVALID_INPUT_CLASSES = ["ring-2", "ring-destructive", "border-destructive"];

  static values = {
    step1Subtitle: { type: String, default: "Step 1 of 2 · Goal details" },
    step2Subtitle: { type: String, default: "Step 2 of 2 · Review & start" },
    cancelLabel: { type: String, default: "Cancel" },
    backLabel: { type: String, default: "Back" },
    continueLabel: { type: String, default: "Continue" },
    submitLabel: { type: String, default: "Create goal" },
  };

  connect() {
    this.currentStep = 1;
    this.refreshSubmitState();
  }

  blockEnter(event) {
    if (this.currentStep !== 1) return;
    // Allow Enter in the notes textarea so newlines work.
    if (event.target.tagName === "TEXTAREA") return;
    event.preventDefault();
    // Mirror Continue: validate + advance instead of swallowing silently.
    this.next();
  }

  footerLeft(event) {
    event.preventDefault();
    this.back();
  }

  footerRight(event) {
    event.preventDefault();
    if (this.currentStep === 1) {
      this.next();
    } else {
      this.submitButtonTarget.click();
    }
  }

  next() {
    if (!this.validateStep1()) return;

    this.currentStep = 2;
    this.step1PanelTarget.classList.add("hidden");
    this.step2PanelTarget.classList.remove("hidden");
    this.updateStepperState();
    this.refreshAccountSelect();
    this.updateReview();
    this.updateFooter();
  }

  back() {
    this.currentStep = 1;
    this.step2PanelTarget.classList.add("hidden");
    this.step1PanelTarget.classList.remove("hidden");
    this.updateStepperState();
    this.updateFooter();
  }

  linkedAccountChanged() {
    this.refreshAccountSelect();
    this.refreshSubmitState();
    this.updateReview();
    if (this.linkedAccountCheckboxTargets.some((cb) => cb.checked) && this.hasAccountsErrorTarget) {
      this.accountsErrorTarget.classList.add("hidden");
    }
  }

  nameChanged() {
    if (this.hasNameInputTarget) {
      this.clearFieldError(this.nameInputTarget, this.hasNameErrorTarget ? this.nameErrorTarget : null);
    }
    if (!this.hasAvatarPreviewTarget || !this.hasNameInputTarget) return;
    const name = this.nameInputTarget.value.trim();
    const initial = name ? name.charAt(0).toUpperCase() : "?";
    const inner = this.avatarPreviewTarget.querySelector('[data-testid="savings-goal-avatar"]');
    if (inner) inner.textContent = initial;
  }

  validateStep1() {
    let ok = true;
    let firstInvalid = null;

    const nameInput = this.hasNameInputTarget ? this.nameInputTarget : null;
    if (nameInput && nameInput.value.trim().length === 0) {
      this.showFieldError(nameInput, this.hasNameErrorTarget ? this.nameErrorTarget : null);
      firstInvalid ||= nameInput;
      ok = false;
    }

    const amountInput = this.hasAmountInputTarget ? this.amountInputTarget : null;
    const amountValue = amountInput ? parseFloat(amountInput.value) : NaN;
    if (amountInput && (!Number.isFinite(amountValue) || amountValue <= 0)) {
      this.showFieldError(amountInput, this.hasAmountErrorTarget ? this.amountErrorTarget : null);
      firstInvalid ||= amountInput;
      ok = false;
    }

    if (!this.linkedAccountCheckboxTargets.some((cb) => cb.checked)) {
      if (this.hasAccountsErrorTarget) this.accountsErrorTarget.classList.remove("hidden");
      ok = false;
    }

    if (firstInvalid) firstInvalid.focus();
    return ok;
  }

  showFieldError(input, errorEl) {
    if (input) input.classList.add(...this.constructor.INVALID_INPUT_CLASSES);
    if (errorEl) errorEl.classList.remove("hidden");
  }

  clearFieldError(input, errorEl) {
    if (input) input.classList.remove(...this.constructor.INVALID_INPUT_CLASSES);
    if (errorEl) errorEl.classList.add("hidden");
  }

  amountChanged() {
    if (this.hasAmountInputTarget) {
      this.clearFieldError(this.amountInputTarget, this.hasAmountErrorTarget ? this.amountErrorTarget : null);
    }
  }

  refreshSubmitState() {
    if (!this.hasFooterRightButtonTarget) return;
    const anyChecked = this.linkedAccountCheckboxTargets.some((cb) => cb.checked);
    this.footerRightButtonTarget.disabled = false;
    this.footerRightButtonTarget.classList.toggle("opacity-50", !anyChecked && this.currentStep === 1);
  }

  refreshAccountSelect() {
    if (!this.hasInitialContributionAccountSelectTarget) return;
    const select = this.initialContributionAccountSelectTarget;
    const previous = select.value;
    while (select.options.length > 1) select.remove(1);

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

  updateStepperState() {
    if (this.hasStep1CircleTarget) {
      this.step1CircleTarget.classList.toggle("bg-inverse", this.currentStep === 1);
      this.step1CircleTarget.classList.toggle("text-inverse", this.currentStep === 1);
      this.step1CircleTarget.classList.toggle("bg-success", this.currentStep > 1);
      this.step1CircleTarget.classList.toggle("text-inverse", this.currentStep === 1);
      if (this.currentStep > 1) {
        this.step1CircleTarget.textContent = "✓";
      } else {
        this.step1CircleTarget.textContent = "1";
      }
    }
    if (this.hasStep2CircleTarget) {
      this.step2CircleTarget.classList.toggle("bg-inverse", this.currentStep === 2);
      this.step2CircleTarget.classList.toggle("text-inverse", this.currentStep === 2);
      this.step2CircleTarget.classList.toggle("border", this.currentStep < 2);
      this.step2CircleTarget.classList.toggle("border-secondary", this.currentStep < 2);
      this.step2CircleTarget.classList.toggle("text-secondary", this.currentStep < 2);
    }
    if (this.hasStepperLineTarget) {
      this.stepperLineTarget.classList.toggle("border-inverse", this.currentStep > 1);
      this.stepperLineTarget.classList.toggle("border-secondary", this.currentStep === 1);
    }
    // Modal subtitle lives in the dialog header, outside this controller's
    // DOM scope. Locate it by attribute and update directly.
    const subtitle = document.querySelector('[data-savings-goal-stepper-modal-subtitle]');
    if (subtitle) {
      subtitle.textContent =
        this.currentStep === 1 ? this.step1SubtitleValue : this.step2SubtitleValue;
    }
  }

  updateFooter() {
    if (this.hasFooterLeftButtonTarget) {
      this.footerLeftButtonTarget.classList.toggle("hidden", this.currentStep === 1);
    }
    if (this.hasFooterRightButtonTarget) {
      const labelSpan = this.footerRightButtonTarget.querySelector("span");
      if (labelSpan) {
        labelSpan.textContent =
          this.currentStep === 1 ? this.continueLabelValue : this.submitLabelValue;
      }
    }
    this.refreshSubmitState();
  }

  updateReview() {
    if (!this.hasReviewNameTarget) return;

    const name = this.element.querySelector('input[name="savings_goal[name]"]')?.value || "—";
    const amountInput = this.element.querySelector('input[name="savings_goal[target_amount]"]');
    const amount = amountInput?.value ? parseFloat(amountInput.value) : 0;
    const dateInput = this.element.querySelector('input[type="date"][name="savings_goal[target_date]"]');
    const dateValue = dateInput?.value;

    this.reviewNameTarget.textContent = name;

    if (this.hasReviewSummaryTarget) {
      const currency = amountInput?.dataset?.currency || "$";
      const formattedAmount = amountInput?.value ? `${currency}${amount.toLocaleString()}` : "—";
      this.reviewSummaryTarget.textContent = dateValue
        ? `${formattedAmount} by ${this.#formatDate(dateValue)}`
        : formattedAmount;
    }

    if (this.hasReviewAccountsTarget) {
      const checked = this.linkedAccountCheckboxTargets.filter((cb) => cb.checked);
      const total = checked.reduce(
        (sum, cb) => sum + parseFloat(cb.dataset.accountBalance || 0),
        0,
      );
      this.reviewAccountsTarget.textContent = checked.length
        ? `${checked.length} ${checked.length === 1 ? "account" : "accounts"} · $${total.toLocaleString()} balance`
        : "—";
    }

    if (this.hasReviewSuggestedTarget) {
      const months = dateValue ? this.#monthsBetween(new Date(), new Date(dateValue)) : 0;
      if (amount > 0 && months > 0) {
        const perMonth = Math.ceil(amount / months);
        this.reviewSuggestedTarget.textContent = `$${perMonth.toLocaleString()}/mo over ${Math.max(1, Math.round(months))} months`;
      } else if (amount > 0) {
        this.reviewSuggestedTarget.textContent = `$${amount.toLocaleString()} (no target date)`;
      } else {
        this.reviewSuggestedTarget.textContent = "—";
      }
    }
  }

  #monthsBetween(from, to) {
    return (to - from) / (1000 * 60 * 60 * 24 * 30.44);
  }

  #formatDate(iso) {
    try {
      const d = new Date(iso);
      return d.toLocaleDateString(undefined, { month: "short", day: "numeric", year: "numeric" });
    } catch (e) {
      return iso;
    }
  }
}
