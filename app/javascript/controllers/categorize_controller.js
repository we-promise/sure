import { Controller } from "@hotwired/stimulus";

export default class extends Controller {
  static targets = ["list", "createRuleCheckbox", "groupingKeyInput", "filter"];
  static values = { assignEntryUrl: String, position: Number };

  connect() {
    this.boundSelectFirst = this.selectFirst.bind(this);
    document.addEventListener("keydown", this.boundSelectFirst);
  }

  disconnect() {
    document.removeEventListener("keydown", this.boundSelectFirst);
  }

  selectFirst(event) {
    if (event.key !== "Enter") return;

    const tag = event.target.tagName;
    if (tag === "BUTTON" || tag === "A") return;

    event.preventDefault();

    const visible = Array.from(
      this.listTarget.querySelectorAll(".filterable-item")
    ).filter((el) => el.style.display !== "none");

    if (visible.length !== 1) return;

    visible[0].click();
  }

  clearFilter(event) {
    if (event.target.tagName !== "BUTTON") return;
    if (!this.hasFilterTarget) return;
    this.filterTarget.value = "";
    this.filterTarget.dispatchEvent(new Event("input"));
  }

  uncheckRule() {
    if (this.hasCreateRuleCheckboxTarget) {
      this.createRuleCheckboxTarget.checked = false;
    }
  }

  assignEntry(event) {
    const select = event.target;
    const categoryId = select.value;
    if (!categoryId) return;

    this.uncheckRule();

    const entryId = select.dataset.entryId;
    const body = new FormData();
    body.append("entry_id", entryId);
    body.append("category_id", categoryId);
    body.append("position", this.positionValue);

    // all_entry_ids[] hidden inputs live inside each Turbo Frame —
    // automatically stay in sync as frames are removed
    this.element.querySelectorAll("input[name='all_entry_ids[]']").forEach((input) => {
      body.append("all_entry_ids[]", input.value);
    });

    fetch(this.assignEntryUrlValue, {
      method: "PATCH",
      credentials: "same-origin",
      headers: {
        "X-CSRF-Token": document.querySelector('meta[name="csrf-token"]')?.content,
        Accept: "text/vnd.turbo-stream.html",
      },
      body,
    })
      .then((r) => r.text())
      .then((html) => Turbo.renderStreamMessage(html));
  }
}
