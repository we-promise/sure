import { Controller } from "@hotwired/stimulus";

// Connects to data-controller="rule--split-action"
// Split rows use real, individually-named form fields (rendered server-side), so this
// controller only handles adding/removing rows and the live summary indicator — it never
// needs to serialize anything into a hidden field itself.
//
// Each row carries its own type (fixed or percentage) rather than the action having a single
// mode — mirrors Rule::ActionExecutor::SplitTransaction, where fixed splits are subtracted
// from the transaction total first and percentage splits then divide whatever's left.
export default class extends Controller {
  static targets = ["row", "rowTemplate", "rowsContainer", "summary", "typeSelect", "shareInput"];
  static values = { fixedLabel: String };

  static MIN_ROWS = 2;
  static AMOUNT_TOLERANCE = 0.01;

  connect() {
    this.updateSummary();
  }

  addRow(e) {
    e.preventDefault();
    // Without this, the click bubbles up to the dialog's "click outside to close"
    // listener and (harmlessly on its own) counts as an outside click.
    e.stopPropagation();

    // Seeded from Date.now() (so it can't collide with existing server-rendered row indices,
    // e.g. 0/1/2 for an already-configured split action) but incremented monotonically from
    // there — two rows added within the same millisecond would otherwise get the same index,
    // producing duplicate field names that silently drop one row.
    this.nextRowIndex ??= Date.now();
    // "SPLIT_ROW_PLACEHOLDER", not "ROW_IDX_PLACEHOLDER": this controller's template can itself
    // be nested inside a brand-new action added by rules_controller.js#addAction(), which does
    // its own global replace of "IDX_PLACEHOLDER" — a substring of "ROW_IDX_PLACEHOLDER" — for
    // the action's own index, corrupting this placeholder before this code ever runs.
    const html = this.rowTemplateTarget.innerHTML.replaceAll(
      "SPLIT_ROW_PLACEHOLDER",
      this.nextRowIndex++,
    );
    this.rowsContainerTarget.insertAdjacentHTML("beforeend", html);
    this.updateSummary();
  }

  removeRow(e) {
    e.preventDefault();
    // Critical here: this handler removes the clicked element from the DOM. Without
    // stopPropagation, the click event keeps bubbling to the dialog's "click outside to
    // close" listener, which checks whether e.target is still contained in the dialog —
    // but the target we just removed no longer is, so the whole "New rule" dialog would
    // incorrectly close itself.
    e.stopPropagation();

    if (this.rowTargets.length <= this.constructor.MIN_ROWS) return;

    e.target.closest("[data-rule--split-action-target='row']").remove();
    this.updateSummary();
  }

  updateSummary() {
    const rows = this.rowTargets.map((row) => ({
      type: row.querySelector("[data-rule--split-action-target='typeSelect']")?.value ?? "percentage",
      share: Number.parseFloat(row.querySelector("[data-rule--split-action-target='shareInput']")?.value) || 0,
    }));

    const fixedRows = rows.filter((row) => row.type === "fixed");
    const percentageRows = rows.filter((row) => row.type === "percentage");
    const fixedTotal = fixedRows.reduce((sum, row) => sum + row.share, 0);
    const percentageTotal = percentageRows.reduce((sum, row) => sum + row.share, 0);

    const parts = [];
    let hasTarget = false;
    let balanced = true;

    if (fixedRows.length > 0) {
      if (percentageRows.length > 0) {
        // Percentage rows absorb whatever's left after the fixed amounts, so there's nothing
        // fixed-specific to balance against here (the sum just needs individually-positive
        // rows, already enforced by the min="0" input constraint).
        parts.push(`${fixedTotal.toFixed(2)} ${this.fixedLabelValue}`);
      } else {
        // No percentage rows: every split is a fixed amount, so the total needs to match the
        // rule's "Amount equal to X" condition (if one is set) — that's the only thing that
        // guarantees every matching transaction has the same total for the fixed amounts to
        // add up to.
        const targetAmount = this.#findExactAmountConditionValue();

        if (targetAmount === null) {
          parts.push(fixedTotal.toFixed(2));
        } else {
          hasTarget = true;
          balanced = Math.abs(fixedTotal - targetAmount) < this.constructor.AMOUNT_TOLERANCE;
          parts.push(`${fixedTotal.toFixed(2)} / ${targetAmount.toFixed(2)}`);
        }
      }
    }

    if (percentageRows.length > 0) {
      hasTarget = true;
      const percentageBalanced = Math.abs(percentageTotal - 100) < this.constructor.AMOUNT_TOLERANCE;
      balanced &&= percentageBalanced;
      parts.push(`${percentageTotal.toFixed(2)}%`);
    }

    this.summaryTarget.textContent = parts.join(" + ");

    // Nothing to compare against yet (pure fixed splits with no amount condition) — leave
    // neutral instead of flagging red before the user has finished setting up the rule.
    if (!hasTarget) {
      this.summaryTarget.classList.remove("text-destructive", "text-success");
      return;
    }

    this.summaryTarget.classList.toggle("text-destructive", !balanced);
    this.summaryTarget.classList.toggle("text-success", balanced);
  }

  // Looks across the whole form (not just this controller's element) for a
  // non-deleted "transaction amount = X" condition and returns its numeric value,
  // or null if no such condition currently exists.
  #findExactAmountConditionValue() {
    const conditionRows = document.querySelectorAll("[data-controller~='rule--conditions']");

    for (const row of conditionRows) {
      if (row.classList.contains("hidden")) continue;

      const typeSelect = row.querySelector("select[name*='[condition_type]']");
      const operatorSelect = row.querySelector("select[name*='[operator]']");
      if (typeSelect?.value !== "transaction_amount" || operatorSelect?.value !== "=") continue;

      // Mirrors Rule::Action#exact_amount_condition_value, which only accepts this
      // condition at the top level or nested inside "and" compounds — an "or"/"any"
      // compound doesn't guarantee it holds for every matching transaction.
      if (!this.#isWithinAndOnlyAncestry(row)) continue;

      const valueInput = row.querySelector("[name*='[value]']");
      const amount = Number.parseFloat(valueInput?.value);
      if (Number.isFinite(amount)) return amount;
    }

    return null;
  }

  #isWithinAndOnlyAncestry(row) {
    let subList = row.parentElement?.closest("[data-rule--conditions-target='subConditionsList']");

    while (subList) {
      const compoundRow = subList.closest("[data-controller~='rule--conditions']");
      const operatorSelect = compoundRow?.querySelector("select[name*='[operator]']");
      if (operatorSelect?.value !== "and") return false;

      subList = compoundRow.parentElement?.closest("[data-rule--conditions-target='subConditionsList']");
    }

    return true;
  }
}
