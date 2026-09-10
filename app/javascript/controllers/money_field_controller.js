import { Controller } from "@hotwired/stimulus";
import { CurrenciesService } from "services/currencies_service";
import parseLocaleFloat from "utils/parse_locale_float";
import parseAmountPaste from "utils/parse_amount_paste";
import evaluateAmountExpression from "utils/evaluate_amount_expression";

// Connects to data-controller="money-field"
// when currency select change, update the input value with the correct placeholder and step
export default class extends Controller {
  static targets = ["amount", "currency", "symbol"];
  static values = {
    precision: Number,
    step: String,
  };

  requestSequence = 0;

  connect() {
    // The amount field's displayed value can use a comma decimal, but the
    // server only accepts a dot (see #canonicalizeForSubmit below), so every
    // form containing this field needs its data intercepted at submit time.
    this.form = this.element.closest("form");
    this.canonicalizeForSubmit = this.canonicalizeForSubmit.bind(this);
    this.form?.addEventListener("formdata", this.canonicalizeForSubmit);
  }

  disconnect() {
    this.form?.removeEventListener("formdata", this.canonicalizeForSubmit);
  }

  handleCurrencyChange(e) {
    const selectedCurrency = e.target.value;
    this.updateAmount(selectedCurrency);
  }

  updateAmount(currency) {
    const requestId = ++this.requestSequence;
    new CurrenciesService().get(currency).then((currencyData) => {
      if (requestId !== this.requestSequence) return;

      this.amountTarget.step =
        this.hasStepValue &&
        this.stepValue !== "" &&
        (this.stepValue === "any" || Number.isFinite(Number(this.stepValue)))
          ? this.stepValue
          : currencyData.step;

      const rawValue = this.amountTarget.value.trim();
      if (rawValue !== "") {
        const parsedAmount = evaluateAmountExpression(rawValue);
        if (parsedAmount !== null) {
          const precision =
            this.hasPrecisionValue && Number.isInteger(this.precisionValue)
              ? this.precisionValue
              : currencyData.default_precision;
          this.amountTarget.value = this.#formatForDisplay(
            parsedAmount,
            precision,
            rawValue,
          );
        }
      }

      this.symbolTarget.innerText = currencyData.symbol;
    }).catch(() => {
      // Catch prevents Unhandled Promise Rejection for network failures.
      // Silently ignored as they are unactionable by the user.
    });
  }

  // Number inputs silently reject pasted formatted values ("20,000 ",
  // "1.234,56", "$1,234.56"), leaving the field blank. Intercept the paste,
  // parse the amount, and insert the plain number instead so copy/paste from
  // statements and spreadsheets just works. Text that is not an amount is left
  // to the browser.
  pasteAmount(event) {
    const text = (event.clipboardData || window.clipboardData)?.getData("text") ?? "";
    const parsed = parseAmountPaste(text);
    if (parsed === null) return;

    event.preventDefault();
    const precision = this.#fieldPrecision();
    this.amountTarget.value =
      precision === null ? String(parsed) : parsed.toFixed(precision);

    // auto_submit_form listens for "change" on number inputs while validation
    // and the goal form's suggestion listen for "input", and assigning .value
    // emits neither.
    this.amountTarget.dispatchEvent(new Event("input", { bubbles: true }));
    this.amountTarget.dispatchEvent(new Event("change", { bubbles: true }));
  }

  // The amount field is a plain text input (not type="number"), so it accepts
  // a comma decimal ("12,50"), a locale-formatted amount ("1.234,56"), or a
  // simple arithmetic expression ("12.50+4.30"), same as pasting does. Runs
  // on blur so the raw text is normalized to a plain number before the field
  // loses focus (including via a submit button click, which blurs the
  // previously focused field before the click fires). Leaves the field
  // untouched when the text isn't a valid amount or expression, so a typo
  // isn't silently replaced with 0 and existing required/numeric validation
  // still catches it on submit.
  normalizeAmount() {
    const raw = this.amountTarget.value;
    if (typeof raw !== "string" || raw.trim() === "") return;

    const result = evaluateAmountExpression(raw);
    if (result === null) return;

    const precision = this.#fieldPrecision();
    this.amountTarget.value = this.#formatForDisplay(result, precision, raw);

    this.amountTarget.dispatchEvent(new Event("input", { bubbles: true }));
    this.amountTarget.dispatchEvent(new Event("change", { bubbles: true }));
  }

  // iOS/Android's decimal keypad (inputmode="decimal") has no +/-/*/÷ keys,
  // so typing an expression on a phone is only possible with a physical
  // keyboard. These buttons (rendered in the template, hidden until the
  // field has focus) insert an operator at the cursor position instead.
  // Bound to "mousedown"/"touchstart", not "click": those fire before the
  // input loses focus, so calling preventDefault() here stops the field
  // from blurring (which would otherwise dismiss the on-screen keyboard).
  insertOperator(event) {
    event.preventDefault();
    const operator = event.params.operator;
    const input = this.amountTarget;

    input.focus();
    const start = input.selectionStart ?? input.value.length;
    const end = input.selectionEnd ?? input.value.length;

    if (typeof input.setRangeText === "function") {
      input.setRangeText(operator, start, end, "end");
    } else {
      input.value = input.value.slice(0, start) + operator + input.value.slice(end);
    }

    input.dispatchEvent(new Event("input", { bubbles: true }));
  }

  // Formats a parsed amount for display, matching the decimal separator the
  // user actually typed: `toFixed` always renders a dot, so a comma typed
  // "12,50" would otherwise flip back to "12.50" the moment the field is
  // normalized. Heuristic: if the raw text the user typed contains a comma
  // at all, they're using a comma decimal convention, so render the result
  // with a comma too.
  #formatForDisplay(amount, precision, raw) {
    const formatted = precision === null ? String(amount) : amount.toFixed(precision);
    return typeof raw === "string" && raw.includes(",")
      ? formatted.replace(".", ",")
      : formatted;
  }

  // The value displayed on screen may use a comma decimal (see
  // #formatForDisplay above), but the server only accepts a dot — Rails'
  // decimal typecast doesn't treat a comma as a decimal point, it just
  // strips it, silently turning "54,43" into 5443. The "formdata" event
  // fires whenever this field's form is serialized — on a native submit and
  // on Turbo's fetch-based one alike — so the submitted entry can be
  // rewritten to the canonical dot form right here, without touching what's
  // still on screen.
  canonicalizeForSubmit(event) {
    if (!this.hasAmountTarget || this.amountTarget.disabled) return;

    const raw = this.amountTarget.value;
    if (typeof raw !== "string" || raw.trim() === "") return;

    const result = evaluateAmountExpression(raw);
    if (result === null) return;

    const precision = this.#fieldPrecision();
    const canonical = precision === null ? String(result) : result.toFixed(precision);
    event.formData.set(this.amountTarget.name, canonical);
  }

  // The amount input's step already carries the selected currency's precision,
  // rendered server-side and refreshed by updateAmount, so it tracks the live
  // currency selection without a second lookup. BTC's step arrives as
  // "1.0e-08", so the decimal count is derived numerically rather than by
  // counting characters. Returns null when the step declares no precision —
  // step="any", which the trade amount, price and fee fields use — so the
  // pasted/normalized value is written unrounded instead of being truncated
  // to a default that would drop a sub-cent crypto price to "0.00".
  #fieldPrecision() {
    if (this.hasPrecisionValue && Number.isInteger(this.precisionValue)) {
      return this.precisionValue;
    }

    const step = Number(this.amountTarget.step);
    if (!Number.isFinite(step) || step <= 0) return null;

    return Math.max(0, Math.ceil(-Math.log10(step)));
  }
}
