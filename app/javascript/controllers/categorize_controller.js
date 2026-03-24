import { Controller } from "@hotwired/stimulus";

export default class extends Controller {
  static targets = [
    "list",
    "dialog",
    "dialogTitle",
    "dialogBody",
    "categoryIdInput",
    "createRuleCheckbox",
    "groupingKeyInput",
  ];

  showConfirmation(event) {
    const categoryId = event.currentTarget.dataset.categoryId;
    const categoryName = event.currentTarget.dataset.categoryName;
    const checkedCount = this.element.querySelectorAll(
      "input[name='entry_ids[]']:checked"
    ).length;
    const createRule = this.hasCreateRuleCheckboxTarget
      ? this.createRuleCheckboxTarget.checked
      : false;
    const groupingKey = this.hasGroupingKeyInputTarget
      ? this.groupingKeyInputTarget.value
      : "";

    this.categoryIdInputTarget.value = categoryId;
    this.dialogTitleTarget.textContent = `Assign ${checkedCount} transaction${checkedCount === 1 ? "" : "s"} to "${categoryName}"`;

    let body = `${checkedCount} transaction${checkedCount === 1 ? "" : "s"} will be categorized as "${categoryName}".`;
    if (createRule && groupingKey) {
      body += ` A rule will also be created to automatically categorize future "${groupingKey}" transactions.`;
    }
    this.dialogBodyTarget.textContent = body;

    this.dialogTarget.showModal();
  }

  closeDialog() {
    this.dialogTarget.close();
  }

  selectFirst(event) {
    if (event.key !== "Enter") return;

    const visible = Array.from(
      this.listTarget.querySelectorAll(".filterable-item")
    ).filter((el) => el.style.display !== "none");

    if (visible.length !== 1) return;

    event.preventDefault();
    visible[0].click();
  }
}
