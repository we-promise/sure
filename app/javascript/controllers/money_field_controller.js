import { Controller } from "@hotwired/stimulus";
import { CurrenciesService } from "services/currencies_service";
import parseAmountPaste from "utils/parse_amount_paste";
import evaluateAmountExpression, {
  amountBoundViolation,
  formatAmountForDisplay,
  formatUnroundedAmount,
  hasWholeNumberGrouping,
  precisionFromStep,
} from "utils/evaluate_amount_expression";

// Connects to data-controller="money-field"
// when currency select change, update the input value with the correct placeholder and step
export default class extends Controller {
  static targets = ["amount", "currency", "symbol"];
  static values = {
    precision: Number,
    step: String,
    min: Number,
    max: Number,
    invalidMessage: String,
    minMessage: String,
    maxMessage: String,
    separator: String,
    delimiter: String,
    separatorCurrency: String,
    currencySource: String,
  };

  requestSequence = 0;

  connect() {
    // The amount field's displayed value can use a comma decimal, but the
    // server only accepts a dot (see #canonicalizeForSubmit below), so every
    // form containing this field needs its data intercepted at submit time.
    this.form = this.element.closest("form");
    this.canonicalizeForSubmit = this.canonicalizeForSubmit.bind(this);
    this.form?.addEventListener("formdata", this.canonicalizeForSubmit);

    // The field is a plain text input (not type="number"), so nothing else
    // stops a second decimal separator from being typed — and an amount
    // evaluateAmountExpression rejects (more than one comma/dot) is left
    // untouched by both #normalizeAmount and #canonicalizeForSubmit below,
    // so it would otherwise reach the server exactly as typed and get
    // silently mismangled by Rails' decimal typecast. Blocking the keystroke
    // that would create a second separator keeps that state unreachable by
    // typing in the first place.
    this.guardSeparator = this.guardSeparator.bind(this);
    this.amountTarget.addEventListener("beforeinput", this.guardSeparator);

    // The field being a text input means the browser applies no numeric
    // constraint at all (unlike the old type="number" field, which refused
    // to even hold a typeMismatch value): without this, an unparseable
    // amount like "100-" or "5/0" is left in the field untouched (by design,
    // see #normalizeAmount below) and would be submitted to the server
    // verbatim, where Rails' lenient decimal typecast (String#to_d) parses
    // only the leading valid portion instead of raising — silently turning
    // "100-" into 100. Tracking validity live on every keystroke (rather
    // than only on blur/submit) means the browser's native constraint
    // validation — which runs before "submit"/"formdata" even fire — is
    // already up to date by the time a submit is attempted, including via
    // Enter in the field, which unlike a submit-button click doesn't blur
    // it first.
    this.updateValidity = this.updateValidity.bind(this);
    this.amountTarget.addEventListener("input", this.updateValidity);
    this.updateValidity();

    // A currency source can change before this controller connects (a parent
    // controller syncing it in its own connect), and that "change" is missed.
    const source = this.#currencySourceElement();
    if (source?.value && source.value !== this.separatorCurrencyValue) {
      this.updateAmount(source.value);
    }
  }

  disconnect() {
    this.form?.removeEventListener("formdata", this.canonicalizeForSubmit);
    this.amountTarget.removeEventListener("beforeinput", this.guardSeparator);
    this.amountTarget.removeEventListener("input", this.updateValidity);
  }

  // A blank field is left to the existing `required` attribute (if any) to
  // flag, not this — only non-empty text that fails to parse as an amount
  // or expression is a typeMismatch-equivalent here. A parseable amount is
  // also checked against the caller's min/max (rangeUnderflow/-Overflow
  // equivalents), which the text input no longer enforces natively — e.g.
  // a trade's price and fee (min: 0) would otherwise accept "-10". Since
  // auto_submit_form submits via requestSubmit(), which runs constraint
  // validation, an out-of-range value is blocked there too.
  updateValidity(event) {
    // An input event is an edit, even one that leaves the same text (select
    // all and paste it again): the text is then the user's for the selected
    // currency.
    if (event?.type === "input") this.unreadText = undefined;

    const raw = this.amountTarget.value.trim();
    if (raw === "") {
      this.amountTarget.setCustomValidity("");
      return;
    }

    const result = this.#isUnreadAfterCurrencySwitch()
      ? null
      : evaluateAmountExpression(raw, this.#readOptions());
    if (result === null) {
      this.amountTarget.setCustomValidity(
        this.invalidMessageValue || "Enter a valid amount or expression.",
      );
      return;
    }

    const violation = amountBoundViolation(result, {
      min: this.hasMinValue ? this.minValue : undefined,
      max: this.hasMaxValue ? this.maxValue : undefined,
      precision: this.#fieldPrecision(),
    });
    const messages = { min: this.minMessageValue, max: this.maxMessageValue };
    this.amountTarget.setCustomValidity(
      violation ? messages[violation] || violation : "",
    );
  }

  // Only guards plain typed characters (inputType "insertText"): paste has
  // its own handling (#pasteAmount, which replaces the whole value with an
  // already-clean parse), and IME composition/autofill are left alone so
  // this never fights a browser or assistive-tech input method. Scoped to
  // the number *token* under the cursor (bounded by +-*/ on either side),
  // not the whole field, so a second operand's own decimal point in an
  // expression like "12,50+4,30" still works — only a second separator
  // within the same number is blocked, unless it's replacing the existing
  // one (a text selection that spans it), so correcting via select-and-
  // retype still works.
  // A whole-number field (precision 0) has no decimal point, so a repeated
  // separator there is thousands grouping ("150.000.000") and is allowed.
  guardSeparator(event) {
    if (event.inputType !== "insertText" || !/[.,]/.test(event.data || "")) return;
    if (this.#fieldPrecision() === 0) return;

    const { selectionStart, selectionEnd, value } = event.target;
    let tokenStart = selectionStart;
    while (tokenStart > 0 && !/[+\-*/]/.test(value[tokenStart - 1])) tokenStart--;
    let tokenEnd = selectionEnd;
    while (tokenEnd < value.length && !/[+\-*/]/.test(value[tokenEnd])) tokenEnd++;

    const existingOffset = value.slice(tokenStart, tokenEnd).search(/[.,]/);
    if (existingOffset === -1) return;
    const existingIndex = tokenStart + existingOffset;
    if (selectionStart <= existingIndex && existingIndex < selectionEnd) return;

    event.preventDefault();
  }

  handleCurrencyChange(e) {
    const selectedCurrency = e.target.value;
    this.updateAmount(selectedCurrency);
  }

  // A field with its currency picker hidden can follow another field's
  // picker in the same form, named by a CSS selector, so its symbol and
  // precision match.
  followCurrencySource(e) {
    if (e.target !== this.#currencySourceElement()) return;

    this.updateAmount(e.target.value);
  }

  updateAmount(currency) {
    const requestId = ++this.requestSequence;
    this.textAtSwitch = this.amountTarget.value;
    new CurrenciesService().get(currency).then((currencyData) => {
      if (requestId !== this.requestSequence) return;

      // Text already there was typed for the previous currency, so it is read
      // with that currency's rules. Text edited while the lookup was pending
      // was typed for the new currency and is read with the new rules, so
      // "1.234" typed after switching JPY to USD is not taken as 1234.
      const typedForNewCurrency = this.#editedSinceSwitch();
      const previousPrecision = this.#fieldPrecision();
      const typedDelimiter = typedForNewCurrency
        ? (currencyData.delimiter ?? "")
        : this.delimiterValue;

      this.amountTarget.step =
        this.hasStepValue &&
        this.stepValue !== "" &&
        (this.stepValue === "any" || Number.isFinite(Number(this.stepValue)))
          ? this.stepValue
          : currencyData.step;

      const typedPrecision = typedForNewCurrency
        ? this.#fieldPrecision()
        : previousPrecision;
      const rawValue = this.amountTarget.value.trim();
      if (rawValue !== "") {
        const wasUnread = this.#isUnreadAfterCurrencySwitch();
        const parsedAmount = wasUnread
          ? null
          : evaluateAmountExpression(rawValue, {
              precision: typedPrecision,
              delimiter: typedDelimiter,
            });
        // Text a whole-number currency rejected but read as grouping stays
        // flagged until it is edited. Read with the new currency's rules it
        // would become valid with another meaning: "150.000*12" is rejected
        // in PYG but would be 1800 in USD. Text that was only invalid
        // ("25.50" typed before picking USD) is read by the new rules. A
        // flagged text keeps its flag through further switches.
        this.unreadText =
          wasUnread ||
          (parsedAmount === null && typedPrecision === 0 && hasWholeNumberGrouping(rawValue))
            ? this.amountTarget.value
            : undefined;
        if (parsedAmount !== null) {
          const precision =
            this.hasPrecisionValue && Number.isInteger(this.precisionValue)
              ? this.precisionValue
              : currencyData.default_precision;
          this.amountTarget.value = formatAmountForDisplay(
            parsedAmount,
            precision,
            rawValue,
          );
        }
      }

      this.symbolTarget.innerText = currencyData.symbol;
      this.separatorValue = currencyData.separator;
      this.delimiterValue = currencyData.delimiter ?? "";
      this.separatorCurrencyValue = currency;
      // The new currency's step can change the rounding the bounds are
      // checked against, and assigning .value above fires no "input".
      this.updateValidity();
      // Assigning .value fires no "input" either, so controllers that derive
      // numbers from this amount hear about the new text and step here.
      this.dispatch("reformatted");
    }).catch(() => {
      // Catch prevents Unhandled Promise Rejection for network failures.
      // Silently ignored as they are unactionable by the user.
    });
  }

  // Number inputs silently reject pasted formatted values ("20,000 ",
  // "1.234,56", "$1,234.56"), leaving the field blank. Intercept the paste,
  // parse the amount, and insert the plain number instead so copy/paste from
  // statements and spreadsheets just works. Text that is not an amount is left
  // to the browser. The selected currency's decimal separator settles pastes
  // that read both ways, so "1,234" in a euro field is 1.234, not 1234.
  pasteAmount(event) {
    const text = (event.clipboardData || window.clipboardData)?.getData("text") ?? "";
    const pending = this.#currencyPending();
    const precision = pending ? null : this.#fieldPrecision();
    // While a currency switch is loading, a paste that reads differently
    // with a dot or a comma decimal ("1,234") is left as pasted text, so the
    // lookup reads it with the new currency's separator when it lands.
    if (pending && this.#pasteReadsBothWays(text)) return;
    const parsed = parseAmountPaste(text, {
      separator: this.#pasteSeparator(),
      precision,
    });
    if (parsed === null) return;

    event.preventDefault();
    this.amountTarget.value =
      precision === null ? formatUnroundedAmount(parsed) : parsed.toFixed(precision);

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

    if (this.#isUnreadAfterCurrencySwitch()) return;
    // The new currency's lookup reformats the text when it lands; rounding
    // it now would use the previous currency's precision.
    if (this.#currencyPending()) return;

    const precision = this.#fieldPrecision();
    const result = evaluateAmountExpression(raw, this.#readOptions());
    if (result === null) return;

    const formatted = formatAmountForDisplay(result, precision, raw);
    // Leaving a field without editing it is not a change: an auto-submitting
    // field listening for "change" must not save on a plain blur.
    if (formatted === raw) return;

    this.amountTarget.value = formatted;
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
  // Also bound to "keydown.enter"/"keydown.space" for keyboard activation;
  // preventDefault there is harmless (DS::Button is type="button", and the
  // only other default it'd stop is page scroll on Space).
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

  // The value displayed on screen may use a comma decimal (see
  // formatAmountForDisplay in evaluate_amount_expression.js), but the
  // server only accepts a dot — Rails' decimal typecast doesn't treat a
  // comma as a decimal point, it just strips it, silently turning "54,43"
  // into 5443. The "formdata" event fires whenever this field's form is
  // serialized — on a native submit and on Turbo's fetch-based one alike —
  // so the submitted entry can be rewritten to the canonical dot form right
  // here, without touching what's still on screen.
  canonicalizeForSubmit(event) {
    if (!this.hasAmountTarget || this.amountTarget.disabled) return;
    // An unnamed field (a helper input such as the exchange-rate tab's
    // destination amount) isn't part of the submitted data.
    if (!this.amountTarget.name) return;

    const canonical = this.#submittedText();
    if (canonical === null) return;

    event.formData.set(this.amountTarget.name, canonical);
  }

  // The amount this field submits as a number, or null when the text is
  // blank or not an amount. Controllers that derive numbers from the field
  // (the exchange-rate tabs) read it here, so they match what is sent.
  submittedAmount() {
    const canonical = this.#submittedText();
    return canonical === null ? null : Number(canonical);
  }

  #submittedText() {
    const raw = this.amountTarget.value;
    if (typeof raw !== "string" || raw.trim() === "") return null;

    if (this.#isUnreadAfterCurrencySwitch()) return null;

    // While a currency switch is still loading, the installed precision is
    // the previous currency's; submit unrounded rather than round to it.
    const precision = this.#currencyPending() ? null : this.#fieldPrecision();
    const result = evaluateAmountExpression(raw, this.#readOptions());
    if (result === null) return null;

    return precision === null ? formatUnroundedAmount(result) : result.toFixed(precision);
  }

  // The separator belongs to the currency it was rendered or last fetched for.
  // While a currency switch is still loading, or after it failed to load, that
  // is not the selected currency, so the paste falls back to the unhinted
  // heuristic instead of settling it with another currency's separator.
  #pasteSeparator() {
    if (this.#currencyPending()) return undefined;

    return this.separatorValue;
  }

  // How typed text is read: the field's precision and its currency's
  // thousands delimiter, which a decimal factor in a whole-number field
  // cannot use (see evaluateAmountExpression). Text edited while a currency
  // switch is loading was typed for the new currency, whose rules are not
  // known yet, so it is read as a plain decimal rather than by the previous
  // currency's grouping rules ("1,234" after JPY to USD is not 1234).
  #readOptions() {
    if (this.#currencyPending() && this.#editedSinceSwitch()) {
      return { precision: null, delimiter: "" };
    }
    return { precision: this.#fieldPrecision(), delimiter: this.delimiterValue };
  }

  #pasteReadsBothWays(text) {
    const withDot = parseAmountPaste(text, { separator: ".", precision: null });
    const withComma = parseAmountPaste(text, { separator: ",", precision: null });
    return withDot !== withComma;
  }

  // True when the text changed after the last currency switch started.
  #editedSinceSwitch() {
    return this.textAtSwitch !== undefined && this.amountTarget.value !== this.textAtSwitch;
  }

  // The text a currency switch could not read (see updateAmount), kept on the
  // amount input so a restored copy of the page (Turbo's cache on back
  // navigation, with a new controller) keeps it.
  get unreadText() {
    return this.amountTarget.dataset.unreadText;
  }

  set unreadText(text) {
    if (text === undefined) {
      delete this.amountTarget.dataset.unreadText;
    } else {
      this.amountTarget.dataset.unreadText = text;
    }
  }

  // True while the field still holds the text a currency switch could not
  // read (see updateAmount). Any edit clears it.
  #isUnreadAfterCurrencySwitch() {
    if (this.unreadText === undefined) return false;
    if (this.amountTarget.value === this.unreadText) return true;

    this.unreadText = undefined;
    return false;
  }

  #currencySourceElement() {
    if (!this.hasCurrencySourceValue) return null;

    return this.form?.querySelector(this.currencySourceValue) ?? null;
  }

  // True while the picked currency's lookup has not landed, so the step and
  // separator still belong to the previous currency.
  #currencyPending() {
    const picker = this.hasCurrencyTarget
      ? this.currencyTarget
      : this.#currencySourceElement();
    return Boolean(picker && picker.value !== this.separatorCurrencyValue);
  }

  // The amount input's step already carries the selected currency's precision,
  // rendered server-side and refreshed by updateAmount, so it tracks the live
  // currency selection without a second lookup. BTC's step arrives as
  // "1.0e-08", so the decimal count is derived numerically rather than by
  // counting characters. Returns null when the step declares no precision —
  // step="any", which the trade amount, price and fee fields and the cost basis
  // editor use — so the pasted/normalized value is written unrounded instead of
  // being truncated to a default or display precision that would drop a
  // sub-cent price to "0.00". step="any" wins over the precision value for that
  // reason.
  #fieldPrecision() {
    if (this.amountTarget.step === "any") return null;

    if (this.hasPrecisionValue && Number.isInteger(this.precisionValue)) {
      return this.precisionValue;
    }

    return precisionFromStep(this.amountTarget.step);
  }
}
