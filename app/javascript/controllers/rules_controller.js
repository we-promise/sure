import { Controller } from "@hotwired/stimulus";

// Connects to data-controller="rules"
export default class extends Controller {
  static targets = [
    "conditionTemplate",
    "conditionGroupTemplate",
    "actionTemplate",
    "conditionsList",
    "actionsList",
    "effectiveDateInput",
  ];

  connect() {
    // Update condition prefixes on first connection (form render on edit)
    this.updateConditionPrefixes();
  }

  addConditionGroup() {
    this.#appendTemplate(
      this.conditionGroupTemplateTarget,
      this.conditionsListTarget,
    );
    this.updateConditionPrefixes();
  }

  addCondition() {
    this.#appendTemplate(
      this.conditionTemplateTarget,
      this.conditionsListTarget,
    );
    this.updateConditionPrefixes();
  }

  addAction() {
    this.#appendTemplate(this.actionTemplateTarget, this.actionsListTarget);
  }

  clearEffectiveDate() {
    this.effectiveDateInputTarget.value = "";
  }

  #appendTemplate(templateEl, listEl) {
    const html = templateEl.innerHTML.replaceAll(
      "IDX_PLACEHOLDER",
      this.#uniqueKey(),
    );

    listEl.insertAdjacentHTML("beforeend", html);
  }

  #uniqueKey() {
    // Must stay numeric: strong params only recognize integer-keyed hashes
    // as nested attributes (ActionController::Parameters.nested_attribute?
    // matches /\A-?\d+\z/), so a "new_1"-style key is silently dropped and
    // the submit fails validation. Date.now() alone can repeat when rows are
    // added in the same millisecond, and a small counter alone can collide
    // with the numeric indexes Rails assigns persisted rows on edit forms,
    // so combine them.
    this.keySequence = (this.keySequence ?? 0) + 1;
    return Date.now() * 1000 + this.keySequence;
  }

  // Updates the prefix visibility of all conditions and condition groups
  // This is also called by the rule/conditions_controller when a subcondition is removed
  updateConditionPrefixes() {
    const conditions = Array.from(this.conditionsListTarget.children);
    let conditionIndex = 0;

    conditions.forEach((condition) => {
      // Only process visible conditions, this prevents conditions that are marked for removal and hidden
      // from being added to the index. This is important when editing a rule.
      if (!condition.classList.contains('hidden')) {
        const prefixEl = condition.querySelector('[data-condition-prefix]');
        if (prefixEl) {
          if (conditionIndex === 0) {
            prefixEl.classList.add('hidden');
          } else {
            prefixEl.classList.remove('hidden');
          }
          conditionIndex++;
        }
      }
    });
  }
}
