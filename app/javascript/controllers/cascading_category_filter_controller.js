import { Controller } from "@hotwired/stimulus";

/**
 * Cascading category filter controller
 *
 * When a parent category is checked, automatically check all its children.
 * When a parent category is unchecked, automatically uncheck all its children.
 * This ensures the UI reflects exactly what will be filtered (works with
 * backend that filters only explicitly selected categories).
 */
export default class extends Controller {
  static targets = ["checkbox"];

  connect() {
    // Build parent-child relationships map
    this.childrenMap = new Map(); // parentId -> [childCheckboxes]
    this.parentMap = new Map(); // childId -> parentCheckbox

    this.checkboxTargets.forEach((checkbox) => {
      const parentId = checkbox.dataset.parentId;
      const categoryId = checkbox.dataset.categoryId;

      if (parentId && parentId !== "null" && parentId !== "") {
        // This is a child - find its parent checkbox
        const parentCheckbox = this.checkboxTargets.find(
          (cb) => cb.dataset.categoryId === parentId
        );

        if (parentCheckbox) {
          this.parentMap.set(categoryId, parentCheckbox);

          if (!this.childrenMap.has(parentId)) {
            this.childrenMap.set(parentId, []);
          }
          this.childrenMap.get(parentId).push(checkbox);
        }
      }
    });
  }

  toggle(event) {
    const checkbox = event.target;
    const categoryId = checkbox.dataset.categoryId;
    const isChecked = checkbox.checked;

    // If this is a parent, cascade to children
    const children = this.childrenMap.get(categoryId);
    if (children && children.length > 0) {
      children.forEach((childCheckbox) => {
        childCheckbox.checked = isChecked;
      });
    }

    // Note: Unchecking a child does NOT uncheck the parent.
    // This allows filtering by parent + some (but not all) children.
  }
}
