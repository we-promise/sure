import { Controller } from "@hotwired/stimulus";

// Submits an arbitrary <form> looked up by DOM id on change/click. Exists
// for elements associated with a form via the HTML form="..." attribute
// instead of DOM nesting (e.g. a popover panel rendered outside the <form>
// it logically belongs to), where auto-submit-form's target-scoping
// (app/javascript/controllers/auto_submit_form_controller.js) can't reach
// them. Prefer auto-submit-form when the element is actually nested inside
// the form it submits.
export default class extends Controller {
  static values = { formId: String };

  submit() {
    document.getElementById(this.formIdValue)?.requestSubmit();
  }
}
