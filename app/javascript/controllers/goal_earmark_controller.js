import { Controller } from "@hotwired/stimulus";

// Tells the user what each funding account still has room for, as they type.
//
// Nothing here is an error, and the wording matters more than the maths: a
// goal in progress legitimately claims more than its account holds. An
// account of 6,000 backing two goals of 5,000 is a correct setup, not an
// over-allocation, so a warning phrased as one would fire permanently. The
// pro-rata message states the consequence instead of scolding.
//
// Deliberately separate from goal-form, which is already at 10 targets
// against the 7 the project guidelines suggest. Three here, and no shared
// state between them.
export default class extends Controller {
  static targets = ["allocationInput", "warning", "checkbox"];
  static values = {
    currency: String,
    locale: String,
    wholeBalance: String,
    prorata: String,
    headroom: String,
    wholeBalanceAlone: String,
  };

  // A complete number, optionally with one decimal separator and digits after
  // it. `Number.parseFloat` alone accepts prefixes — "500abc" becomes 500 —
  // and a bare comma-to-dot swap turns the thousands-separated "1,500" into
  // 1.5, so a typo or a habit from another locale silently changed the amount
  // the preview was based on.
  static ALLOCATION_PATTERN = /^\d+(?:[.,]\d+)?$/;

  /** Initialize the account allocation hints when the form is mounted. */
  connect() {
    this.refresh();
  }

  /** Recompute hints for every visible native-currency allocation input. */
  refresh() {
    this.allocationInputTargets.forEach((input) => this.#refreshRow(input));
  }

  /**
   * Update one account hint from its checkbox, native balance and earmark.
   * @param {HTMLInputElement} input The account allocation field.
   * @returns {void}
   */
  #refreshRow(input) {
    const row = input.closest("[data-balance]");
    if (!row) return;

    const warning = row.querySelector('[data-goal-earmark-target="warning"]');
    const checkbox = row.querySelector('input[type="checkbox"]');
    if (!warning) return;

    // An unchecked account funds nothing, so it has nothing to say.
    if (checkbox && !checkbox.checked) return this.#hide(warning);

    const balance = Number.parseFloat(row.dataset.balance || "0");
    const others = Number.parseFloat(row.dataset.earmarkedByOthers || "0");
    // A whole-account link elsewhere sums to zero above, so the amount alone
    // cannot tell "nobody else claims this" from "somebody claims all of it".
    const claimedWhole = row.dataset.wholeAccountClaimed === "true";
    const raw = input.value.trim();

    // A number input reports text it cannot parse as "", which would read as
    // a blank amount and claim the whole balance for what the user typed.
    if (input.validity?.badInput) return this.#hide(warning);

    // "whatever is left after the other earmarks" describes nothing when there
    // are none — and this is where a first-time user meets the word, pointed
    // at something absent. With the account to itself, say that instead.
    if (raw === "") {
      return this.#show(
        warning,
        others > 0 || claimedWhole
          ? this.wholeBalanceValue
          : this.wholeBalanceAloneValue,
      );
    }

    if (!this.constructor.ALLOCATION_PATTERN.test(raw))
      return this.#hide(warning);

    const entered = Number.parseFloat(raw.replace(",", "."));
    if (Number.isNaN(entered)) return this.#hide(warning);

    const total = others + entered;

    if (total > balance) {
      this.#show(
        warning,
        this.prorataValue
          .replace("{total}", this.#money(total, row.dataset.currency))
          .replace("{balance}", this.#money(balance, row.dataset.currency)),
      );
    } else {
      this.#show(
        warning,
        this.headroomValue.replace(
          "{left}",
          this.#money(balance - total, row.dataset.currency),
        ),
      );
    }
  }

  /** Show a localized hint without interpreting its contents as HTML. */
  #show(element, text) {
    element.textContent = text;
    element.classList.remove("hidden");
  }

  /** Hide the hint for an unchecked account or an invalid allocation. */
  #hide(element) {
    element.classList.add("hidden");
  }

  /**
   * Format a native account amount using the application locale.
   * @param {number} value The native-currency amount.
   * @param {string} currency The account ISO code, falling back to the form currency.
   * @returns {string} A localized amount or a readable fallback.
   */
  #money(value, currency = this.currencyValue || "USD") {
    try {
      return new Intl.NumberFormat(this.localeValue || undefined, {
        style: "currency",
        currency,
        maximumFractionDigits: 0,
      }).format(value);
    } catch {
      return `${currency}${Math.round(value).toLocaleString()}`;
    }
  }
}
