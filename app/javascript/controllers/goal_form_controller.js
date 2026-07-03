import { Controller } from "@hotwired/stimulus";

// Single-form controller for the goal create / edit modal.
//
// Replaces the 2-step stepper: the form is short enough that all fields
// fit on one panel, so the previous review step (which only showed a
// derived "Save $X/mo to hit it on time" hint) collapses into an inline
// live hint below the target date. Validation + avatar preview from the
// name field still live here.
export default class extends Controller {
  static targets = [
    "nameInput",
    "amountInput",
    "dateInput",
    "avatarPreview",
    "nameError",
    "amountError",
    "accountsError",
    "linkedAccountCheckbox",
    "suggested",
    "submitButton",
  ];

  static INVALID_INPUT_CLASSES = ["ring-2", "ring-destructive", "border-destructive"];

  static values = {
    currency: { type: String, default: "USD" },
    suggestedWithDate: { type: String, default: "Save {monthly}/mo across {accounts} to hit it on time." },
    suggestedNoDate: { type: String, default: "Set a target date to project a finish line." },
    // Only the create form must pick an account. On edit the checkboxes are
    // populated from visible accounts only, so a goal backed by a now-hidden
    // account renders none — and the controller preserves existing links when
    // account_ids is omitted. Requiring a checkbox there would wedge the form.
    requireAccount: { type: Boolean, default: true },
  };

  connect() {
    // Capture the default avatar contents (the "target" icon SVG) so we
    // can restore it when the user clears the name field after typing.
    if (this.hasAvatarPreviewTarget) {
      this._defaultAvatarHTML = this.avatarPreviewTarget.innerHTML;
    }
    this.updateSuggested();
    // Edit form arrives pre-filled (valid) so this clears immediately; new
    // form arrives empty so the submit starts visually disabled.
    this.refreshSubmitState();
  }

  nameChanged() {
    if (this.hasNameInputTarget) {
      this.clearFieldError(this.nameInputTarget, this.hasNameErrorTarget ? this.nameErrorTarget : null);
    }
    this.refreshSubmitState();
    if (!this.hasAvatarPreviewTarget || !this.hasNameInputTarget) return;

    // If the user has explicitly picked an icon, leave it alone. Name
    // changes shouldn't undo an explicit choice.
    const iconPicked = this.element.querySelector('input[name="goal[icon]"]:checked');
    if (iconPicked) return;

    const name = this.nameInputTarget.value.trim();
    if (name) {
      this.avatarPreviewTarget.textContent = name.charAt(0).toUpperCase();
    } else if (this._defaultAvatarHTML) {
      // Captured at connect. Restore the default "target" icon from the
      // server-rendered template, not a "?" character.
      this.avatarPreviewTarget.innerHTML = this._defaultAvatarHTML;
    }
  }

  amountChanged() {
    if (this.hasAmountInputTarget) {
      this.clearFieldError(this.amountInputTarget, this.hasAmountErrorTarget ? this.amountErrorTarget : null);
    }
    this.refreshSubmitState();
  }

  linkedAccountChanged() {
    this.updateSuggested();
    if (this.linkedAccountCheckboxTargets.some((cb) => cb.checked) && this.hasAccountsErrorTarget) {
      this.accountsErrorTarget.classList.add("hidden");
    }
    this.refreshSubmitState();
  }

  // Required to create a goal: a name, a positive target amount, and at least
  // one funding account. Mirrors the server-side Goal validations (name
  // presence, target_amount > 0, must_have_at_least_one_linked_account) so the
  // button only enables when a submit would actually succeed.
  isValid() {
    const name = this.hasNameInputTarget ? this.nameInputTarget.value.trim() : "";
    const amount = this.hasAmountInputTarget ? Number.parseFloat(this.amountInputTarget.value) : Number.NaN;
    const accountOk = !this.requireAccountValue || this.linkedAccountCheckboxTargets.some((cb) => cb.checked);
    return name.length > 0 && Number.isFinite(amount) && amount > 0 && accountOk;
  }

  // `aria-disabled` instead of the `disabled` attribute: a truly disabled
  // default submit also blocks Enter-key implicit submission, so an invalid
  // form would be a dead button with every inline error still hidden. With
  // aria-disabled the button keeps its not-allowed affordance (styled via the
  // DS `aria-disabled:` variants) while clicks and Enter still reach
  // validateOnSubmit, which surfaces the errors and moves focus.
  refreshSubmitState() {
    if (this.hasSubmitButtonTarget) {
      this.submitButtonTarget.setAttribute("aria-disabled", String(!this.isValid()));
    }
  }

  // The real gate for the submit: covers the funding-accounts group (a
  // checkbox group can't carry native `required`) and everything the
  // aria-disabled affordance merely hints at. Surfaces the inline errors and
  // focuses the first offending field instead of a silent no-op.
  validateOnSubmit(event) {
    if (this.isValid()) return;

    event.preventDefault();

    const nameEmpty = !(this.hasNameInputTarget && this.nameInputTarget.value.trim().length > 0);
    const amount = this.hasAmountInputTarget ? Number.parseFloat(this.amountInputTarget.value) : Number.NaN;
    const amountInvalid = !(Number.isFinite(amount) && amount > 0);
    const noAccount = this.requireAccountValue && !this.linkedAccountCheckboxTargets.some((cb) => cb.checked);

    if (nameEmpty) {
      this.showFieldError(this.nameInputTarget, this.hasNameErrorTarget ? this.nameErrorTarget : null);
    }
    if (amountInvalid) {
      this.showFieldError(this.amountInputTarget, this.hasAmountErrorTarget ? this.amountErrorTarget : null);
    }
    if (noAccount && this.hasAccountsErrorTarget) {
      this.accountsErrorTarget.classList.remove("hidden");
    }

    const firstInvalid = nameEmpty
      ? this.nameInputTarget
      : amountInvalid
        ? this.amountInputTarget
        : noAccount
          ? this.linkedAccountCheckboxTargets[0]
          : null;
    firstInvalid?.focus();
  }

  // Hook for any input that influences the suggested-pace hint
  // (target_amount, target_date). Also re-evaluates as accounts toggle.
  suggestedChanged() {
    this.amountChanged();
    this.updateSuggested();
  }

  updateSuggested() {
    if (!this.hasSuggestedTarget) return;

    const amount = this.hasAmountInputTarget ? Number.parseFloat(this.amountInputTarget.value) : Number.NaN;
    const dateValue = this.hasDateInputTarget ? this.dateInputTarget.value : null;
    const checkedCount = this.linkedAccountCheckboxTargets.filter((cb) => cb.checked).length;

    const amountValid = Number.isFinite(amount) && amount > 0;
    if (!amountValid || checkedCount === 0) {
      this.suggestedTarget.classList.add("hidden");
      this.suggestedTarget.textContent = "";
      return;
    }

    let text;
    if (dateValue) {
      const months = this.#monthsBetween(new Date(), new Date(dateValue));
      if (months <= 0) {
        this.suggestedTarget.classList.add("hidden");
        this.suggestedTarget.textContent = "";
        return;
      }
      const perMonth = Math.ceil(amount / months);
      const accountLabel = `${checkedCount} ${checkedCount === 1 ? "account" : "accounts"}`;
      text = this.suggestedWithDateValue
        .replace("{monthly}", this.#money(perMonth))
        .replace("{accounts}", accountLabel);
    } else {
      text = this.suggestedNoDateValue;
    }

    this.suggestedTarget.textContent = text;
    this.suggestedTarget.classList.remove("hidden");
  }

  showFieldError(input, errorEl) {
    if (input) input.classList.add(...this.constructor.INVALID_INPUT_CLASSES);
    if (errorEl) errorEl.classList.remove("hidden");
  }

  clearFieldError(input, errorEl) {
    if (input) input.classList.remove(...this.constructor.INVALID_INPUT_CLASSES);
    if (errorEl) errorEl.classList.add("hidden");
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
}
