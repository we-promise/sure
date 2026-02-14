import { Controller } from "@hotwired/stimulus";

// Connects to data-controller="rule--actions"
export default class extends Controller {
  static values = {
    actionExecutors: Array,
    comboboxUrl: String,
    fieldName: String
  };
  static targets = [
    "destroyField",
    "actionValue",
    "selectTemplate",
    "textTemplate"
  ];

  remove(e) {
    if (e.params.destroy) {
      this.destroyFieldTarget.value = true;
      this.element.classList.add("hidden");
    } else {
      this.element.remove();
    }
  }

  handleActionTypeChange(e) {
    const actionExecutor = this.actionExecutorsValue.find(
      (executor) => executor.key === e.target.value,
    );

    // Clear any existing input elements first
    this.#clearFormFields();

    if (actionExecutor.type === "select") {
      this.#buildComboboxFor(actionExecutor);
    } else if (actionExecutor.type === "text") {
      this.#buildTextInputFor();
    } else {
      // Hide for any type that doesn't need a value (e.g. function)
      this.#hideActionValue();
    }
  }

  #hideActionValue() {
    this.actionValueTarget.classList.add("hidden");
  }

  #clearFormFields() {
    // Remove all children from actionValueTarget
    this.actionValueTarget.innerHTML = "";
  }

  async #buildComboboxFor(actionExecutor) {
    // Show loading state
    this.actionValueTarget.classList.remove("hidden");

    // Fetch combobox HTML from server
    const url = new URL(this.comboboxUrlValue, window.location.origin);
    url.searchParams.set("action_type", actionExecutor.key);
    url.searchParams.set("field_name", this.fieldNameValue);

    try {
      const response = await fetch(url, {
        headers: {
          "Accept": "text/html",
          "X-Requested-With": "XMLHttpRequest"
        }
      });

      if (response.ok) {
        const html = await response.text();
        this.actionValueTarget.innerHTML = html;
      } else {
        // Fallback to plain select on error
        this.#buildSelectFallback(actionExecutor);
      }
    } catch (error) {
      console.error("Failed to load combobox:", error);
      // Fallback to plain select on error
      this.#buildSelectFallback(actionExecutor);
    }
  }

  #buildSelectFallback(actionExecutor) {
    // Clone the select template as fallback
    const template = this.selectTemplateTarget.content.cloneNode(true);
    const selectEl = template.querySelector("select");

    if (selectEl) {
      selectEl.innerHTML = "";
      if (!actionExecutor.options || actionExecutor.options.length === 0) {
        selectEl.disabled = true;
        const optionEl = document.createElement("option");
        optionEl.textContent = "(none)";
        selectEl.appendChild(optionEl);
      } else {
        selectEl.disabled = false;
        for (const option of actionExecutor.options) {
          const optionEl = document.createElement("option");
          optionEl.value = option[1];
          optionEl.textContent = option[0];
          selectEl.appendChild(optionEl);
        }
      }
    }

    this.actionValueTarget.appendChild(template);
  }

  #buildTextInputFor() {
    // Clone the text template
    const template = this.textTemplateTarget.content.cloneNode(true);

    // Ensure the input is always empty
    const inputEl = template.querySelector("input");
    if (inputEl) inputEl.value = "";

    // Add the template content to the actionValue target and ensure it's visible
    this.actionValueTarget.appendChild(template);
    this.actionValueTarget.classList.remove("hidden");
  }
}
