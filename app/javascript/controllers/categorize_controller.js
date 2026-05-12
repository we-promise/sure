import { Controller } from "@hotwired/stimulus";

export default class extends Controller {
  static targets = [
    "list",
    "createRuleCheckbox",
    "filterDisplay",
    "filterEditTrigger",
    "filterEditArea",
    "filterInput",
    "groupingKeyHidden",
    "filter",
    "ruleDetails",
  ];
  static values = { assignEntryUrl: String, position: Number, previewRuleUrl: String, transactionType: String };

  connect() {
    this.boundSelectFirst = this.selectFirst.bind(this);
    document.addEventListener("keydown", this.boundSelectFirst);
    this.toggleRuleDetails();
  }

  disconnect() {
    document.removeEventListener("keydown", this.boundSelectFirst);
    clearTimeout(this._previewTimer);
  }

  selectFirst(event) {
    if (event.key !== "Enter") return;

    const tag = event.target.tagName;
    if (tag === "BUTTON" || tag === "A") return;

    // Don't intercept Enter when the user is confirming an inline filter edit
    if (this.hasFilterInputTarget && event.target === this.filterInputTarget) return;

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
      this.toggleRuleDetails();
    }
  }

  toggleRuleDetails() {
    if (!this.hasRuleDetailsTarget || !this.hasCreateRuleCheckboxTarget) return;
    const enabled = this.createRuleCheckboxTarget.checked;
    this.ruleDetailsTarget.classList.toggle("opacity-40", !enabled);
    if (this.hasFilterInputTarget) {
      this.filterInputTarget.disabled = !enabled;
    }
  }

  startFilterEdit() {
    this.filterDisplayTarget.classList.add("hidden");
    this.filterEditTriggerTarget.classList.add("hidden");
    this.filterEditAreaTarget.classList.remove("hidden");
    this.filterEditAreaTarget.classList.add("flex");
    this.filterInputTarget.focus();
    this.filterInputTarget.select();
  }

  confirmFilterEdit(event) {
    event.preventDefault();
    event.stopPropagation();
    const value = this.filterInputTarget.value.trim();
    if (!value) return;

    this.filterDisplayTarget.textContent = `"${value}"`;
    this.groupingKeyHiddenTarget.value = value;

    this.filterEditAreaTarget.classList.add("hidden");
    this.filterEditAreaTarget.classList.remove("flex");
    this.filterDisplayTarget.classList.remove("hidden");
    this.filterEditTriggerTarget.classList.remove("hidden");

    this._doPreviewRule(value);
  }

  cancelFilterEdit(event) {
    event.preventDefault();
    event.stopPropagation();
    this.filterEditAreaTarget.classList.add("hidden");
    this.filterEditAreaTarget.classList.remove("flex");
    this.filterDisplayTarget.classList.remove("hidden");
    this.filterEditTriggerTarget.classList.remove("hidden");
  }

  previewRule(event) {
    this._doPreviewRule(event.target.value);
  }

  _doPreviewRule(filter) {
    clearTimeout(this._previewTimer);
    this._previewTimer = setTimeout(() => {
      const url = new URL(this.previewRuleUrlValue, window.location.origin);
      url.searchParams.set("filter", filter);
      url.searchParams.set("position", this.positionValue);
      url.searchParams.set("transaction_type", this.transactionTypeValue);
      fetch(url.toString(), {
        credentials: "same-origin",
        headers: {
          "X-CSRF-Token": document.querySelector('meta[name="csrf-token"]')?.content,
          Accept: "text/vnd.turbo-stream.html",
        },
      })
        .then((r) => { if (!r.ok) throw new Error(r.statusText); return r.text(); })
        .then((html) => Turbo.renderStreamMessage(html))
        .catch((err) => console.error("Rule preview failed:", err));
    }, 300);
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
      .then((r) => { if (!r.ok) throw new Error(r.statusText); return r.text(); })
      .then((html) => Turbo.renderStreamMessage(html))
      .catch((err) => {
        console.error("Entry assignment failed:", err);
        select.value = "";
      });
  }
}
