import { Controller } from "@hotwired/stimulus";

// Cascading parent/subcategory checkboxes for the transaction category filter.
//
// A parent checkbox is only ever `checked` (and therefore only ever submitted
// with the form) when *all* of its children are checked. The backend query
// (Transaction::Search#apply_category_filter) includes every subcategory
// whenever a parent category name is present in the submitted params, with
// no way to exclude an individual child. So the moment a user unchecks one
// child, the parent must be unchecked too — otherwise the parent would still
// be submitted and the backend would silently keep including the
// deselected child's transactions, ignoring what the user just did.
export default class extends Controller {
  static targets = ["checkbox"];

  connect() {
    this.checkboxTargets.forEach((checkbox) => {
      if (checkbox.dataset.parentId) {
        this.syncParentState(checkbox.dataset.parentId);
      }
    });
  }

  toggle(event) {
    const checkbox = event.target;
    const categoryId = checkbox.dataset.categoryId;

    const children = this.childCheckboxesFor(categoryId);
    children.forEach((child) => {
      child.checked = checkbox.checked;
      child.indeterminate = false;
    });

    const parentId = checkbox.dataset.parentId;
    if (parentId) {
      this.syncParentState(parentId);
    }
  }

  childCheckboxesFor(parentId) {
    if (!parentId) return [];
    return this.checkboxTargets.filter((cb) => cb.dataset.parentId === parentId);
  }

  syncParentState(parentId) {
    const parentCheckbox = this.checkboxTargets.find(
      (cb) => cb.dataset.categoryId === parentId,
    );
    if (!parentCheckbox) return;

    const children = this.childCheckboxesFor(parentId);
    if (children.length === 0) return;

    const checkedCount = children.filter((cb) => cb.checked).length;

    parentCheckbox.checked = checkedCount === children.length;
    parentCheckbox.indeterminate = checkedCount > 0 && checkedCount < children.length;
  }
}
