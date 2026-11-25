import { Controller } from "@hotwired/stimulus";

// Connects to data-controller="rule--conditions"
export default class extends Controller {
  static values = { conditionFilters: Array, valuelessOperators: Array };
  static targets = [
    "destroyField",
    "filterValue",
    "operatorSelect",
    "subConditionTemplate",
    "subConditionsList",
    "amountValueTemplate",
  ];

  connect() {
    // Hide value field on initial load for valueless operators (e.g. "is_null")
    this.#toggleValueFieldVisibility();
  }

  addSubCondition() {
    const html = this.subConditionTemplateTarget.innerHTML.replaceAll(
      "IDX_CHILD_PLACEHOLDER",
      this.#uniqueKey(),
    );

    this.subConditionsListTarget.insertAdjacentHTML("beforeend", html);
  }

  remove(e) {
    e.preventDefault();
    e.stopPropagation();
    
    // Find the parent rules controller before removing the condition
    const rulesEl = this.element.closest('[data-controller~="rules"]');

    if (e.params.destroy) {
      this.destroyFieldTarget.value = true;
      this.element.classList.add("hidden");
    } else {
      this.element.remove();
    }

    // Update the prefixes of all conditions from the parent rules controller
    if (rulesEl) {
      const rulesController = this.application.getControllerForElementAndIdentifier(rulesEl, "rules");
      if (rulesController && typeof rulesController.updateConditionPrefixes === "function") {
        rulesController.updateConditionPrefixes();
      }
    }
  }

  handleConditionTypeChange(e) {
    const conditionFilter = this.conditionFiltersValue.find(
      (filter) => filter.key === e.target.value,
    );

    if (conditionFilter.type === "select") {
      this.#buildSelectFor(conditionFilter);
    } else {
      this.#buildTextInputFor(conditionFilter);
    }

    this.#updateOperatorsField(conditionFilter);
    this.#toggleValueFieldVisibility();
  }

  handleOperatorChange(e) {
    this.#toggleValueFieldVisibility();
  }

  get valueInputEl() {
    const textInput = this.filterValueTarget.querySelector("input");
    const selectInput = this.filterValueTarget.querySelector("select");

    return textInput || selectInput;
  }

  #updateOperatorsField(conditionFilter) {
    this.operatorSelectTarget.innerHTML = "";

    for (const operator of conditionFilter.operators) {
      const optionEl = document.createElement("option");
      optionEl.value = operator[1];
      optionEl.textContent = operator[0];
      this.operatorSelectTarget.appendChild(optionEl);
    }
  }

  #buildSelectFor(conditionFilter) {
    const selectEl = this.#convertFormFieldTo("select", this.valueInputEl);

    for (const option of conditionFilter.options) {
      const optionEl = document.createElement("option");
      optionEl.value = option[1];
      optionEl.textContent = option[0];
      selectEl.appendChild(optionEl);
    }

    this.#replaceValueField(selectEl);
  }

  // An amount filter gets the same money field as every amount in the app,
  // rendered into the template by the server; the others a plain text input.
  #buildTextInputFor(conditionFilter) {
    if (conditionFilter.type === "number" && this.hasAmountValueTemplateTarget) {
      this.filterValueTarget.replaceChildren(this.amountValueTemplateTarget.content.cloneNode(true));
      return;
    }

    const textInput = this.#convertFormFieldTo("input", this.valueInputEl);
    textInput.placeholder = "Enter a value";
    textInput.type = conditionFilter.type;
    if (conditionFilter.type === "number") {
      textInput.step = conditionFilter.number_step;
    }

    this.#replaceValueField(textInput);
  }

  // A money field brings its own wrapper and controller, so leaving one
  // replaces the whole field with the styled wrapper a plain field has.
  #replaceValueField(field) {
    if (!this.filterValueTarget.querySelector("[data-controller~='money-field']")) {
      this.valueInputEl.replaceWith(field);
      return;
    }

    const body = document.createElement("div");
    body.classList.add("form-field__body");
    body.appendChild(field);
    const wrapper = document.createElement("div");
    wrapper.classList.add("form-field");
    wrapper.appendChild(body);
    this.filterValueTarget.replaceChildren(wrapper);
  }

  #convertFormFieldTo(type, el) {
    const priorClasses = el.classList;
    const priorId = el.id;
    const priorName = el.name;

    const newFormField = document.createElement(type);
    newFormField.classList.add(...priorClasses);
    newFormField.id = priorId;
    newFormField.name = priorName;

    return newFormField;
  }

  #uniqueKey() {
    this.keySequence = (this.keySequence ?? 0) + 1;
    return Date.now() * 1000 + this.keySequence;
  }

  #toggleValueFieldVisibility() {
    const operator = this.operatorSelectTarget.value;

    if (this.valuelessOperatorsValue.includes(operator)) {
      this.filterValueTarget.classList.add("hidden");
      // Clear the value since it's not needed
      if (this.valueInputEl) {
        this.valueInputEl.value = "";
      }
    } else {
      this.filterValueTarget.classList.remove("hidden");
    }
  }
}
