import { Controller } from "@hotwired/stimulus";

// 2-step modal stepper for creating a goal.
//
// Single <form> with two panels. Step 1 collects identity (name, amount,
// date, color, notes, linked accounts). Step 2 reviews and submits. All
// state lives in the DOM — no half-records, single POST.
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
    "reviewName",
    "reviewSummary",
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
    currency: { type: String, default: "USD" },
    summaryWithDate: { type: String, default: "{amount} by {date}" },
    summaryNoDate: { type: String, default: "{amount}" },
    accountCountOne: { type: String, default: "1 account" },
    accountCountOther: { type: String, default: "{count} accounts" },
    suggestedWithDate: { type: String, default: "Save {monthly}/mo across {accounts} to hit it on time." },
    suggestedNoDate: { type: String, default: "Set a target date to project a finish line." },
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
    const inner = this.avatarPreviewTarget.querySelector('[data-testid="goal-avatar"]');
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
    const amountValue = amountInput ? Number.parseFloat(amountInput.value) : Number.NaN;
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
      this.stepperLineTarget.classList.toggle("border-subdued", this.currentStep === 1);
    }
    // Modal subtitle lives in the dialog header, outside this controller's
    // DOM scope. Locate it by attribute and update directly.
    const subtitle = document.querySelector('[data-goal-stepper-modal-subtitle]');
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

    const name = this.element.querySelector('input[name="goal[name]"]')?.value || "—";
    const amountInput = this.element.querySelector('input[name="goal[target_amount]"]');
    const amount = amountInput?.value ? Number.parseFloat(amountInput.value) : 0;
    const dateInput = this.element.querySelector('input[type="date"][name="goal[target_date]"]');
    const dateValue = dateInput?.value;
    const checked = this.linkedAccountCheckboxTargets.filter((cb) => cb.checked);

    this.reviewNameTarget.textContent = name;

    if (this.hasReviewSummaryTarget) {
      const formattedAmount = amount > 0 ? this.#money(amount) : "—";
      const template = dateValue ? this.summaryWithDateValue : this.summaryNoDateValue;
      this.reviewSummaryTarget.textContent = template
        .replace("{amount}", formattedAmount)
        .replace("{date}", dateValue ? this.#formatDate(dateValue) : "");
    }

    if (this.hasReviewSuggestedTarget) {
      const months = dateValue ? this.#monthsBetween(new Date(), new Date(dateValue)) : 0;
      const accountLabel = checked.length === 1
        ? this.accountCountOneValue
        : this.accountCountOtherValue.replace("{count}", checked.length.toString());

      if (amount > 0 && months > 0 && checked.length > 0) {
        const perMonth = Math.ceil(amount / months);
        this.reviewSuggestedTarget.textContent = this.suggestedWithDateValue
          .replace("{monthly}", this.#money(perMonth))
          .replace("{accounts}", accountLabel);
      } else if (amount > 0 && checked.length > 0) {
        this.reviewSuggestedTarget.textContent = this.suggestedNoDateValue;
      } else {
        this.reviewSuggestedTarget.textContent = "—";
      }
    }
  }

  #money(value) {
    try {
      return new Intl.NumberFormat(undefined, {
        style: "currency",
        currency: this.currencyValue || "USD",
        maximumFractionDigits: 0,
      }).format(value);
    } catch {
      return `${this.currencyValue || "$"}${Math.round(value).toLocaleString()}`;
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
