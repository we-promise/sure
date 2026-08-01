import { Controller } from "@hotwired/stimulus";

export default class extends Controller {
  static targets = [
    "list",
    "createRuleCheckbox",
    "filterInput",
    "groupingKeyHidden",
    "filter",
    "ruleDetails",
    "categoryPill",
    "selectedCategoryId",
    "applyButton",
    "applyLabel",
    "selectionSummary",
  ];
  static values = {
    assignEntryUrl: String,
    position: Number,
    previewRuleUrl: String,
    transactionType: String,
  };

  connect() {
    this.boundHandleEnter = this.handleEnter.bind(this);
    document.addEventListener("keydown", this.boundHandleEnter);
    this.toggleRuleDetails();
    this.refreshApplyState();
  }

  disconnect() {
    document.removeEventListener("keydown", this.boundHandleEnter);
    clearTimeout(this._previewTimer);
  }

  // Keyboard path: type in the (autofocused) search, Enter selects the only
  // visible pill, Enter again commits. One gesture per step, no mouse travel.
  handleEnter(event) {
    if (event.key !== "Enter") return;

    const tag = event.target.tagName;
    if (tag === "BUTTON" || tag === "A" || tag === "SELECT") return;
    if (this.hasFilterInputTarget && event.target === this.filterInputTarget) return;

    event.preventDefault();

    const visible = this.categoryPillTargets.filter((el) => el.style.display !== "none");
    if (visible.length === 1 && visible[0].getAttribute("aria-pressed") !== "true") {
      visible[0].click();
      return;
    }

    if (this.selectedCategoryIdTarget.value && !this.applyButtonTarget.disabled) {
      this.applyButtonTarget.form?.requestSubmit(this.applyButtonTarget);
    }
  }

  // Pills select rather than submit; the action bar commits. The search text
  // is deliberately NOT cleared here — wiping it reflows the grid and the
  // just-picked pill jumps elsewhere, right when the user is looking at it.
  selectCategory(event) {
    const pill = event.currentTarget;
    this.categoryPillTargets.forEach((el) => el.setAttribute("aria-pressed", "false"));
    pill.setAttribute("aria-pressed", "true");
    this.selectedCategoryIdTarget.value = pill.value;
    this.refreshApplyState();
  }

  refreshApplyState() {
    if (!this.hasApplyButtonTarget) return;

    const selected = this.categoryPillTargets.find(
      (el) => el.getAttribute("aria-pressed") === "true"
    );
    const count = this.checkedEntryCount;
    const ready = Boolean(selected) && count > 0;

    this.applyButtonTarget.disabled = !ready;

    if (this.hasApplyLabelTarget) {
      const d = this.applyLabelTarget.dataset;
      this.applyLabelTarget.textContent = ready
        ? (count === 1 ? d.templateOne : d.templateOther)
            .replace("%{category}", selected.dataset.categoryName)
            .replace("%{count}", count)
        : d.default;
    }

    if (this.hasSelectionSummaryTarget) {
      this.selectionSummaryTarget.textContent =
        ready && this.createRuleCheckboxTarget?.checked
          ? this.selectionSummaryTarget.dataset.ruleNotice
          : "";
    }
  }

  get checkedEntryCount() {
    return this.element.querySelectorAll("input[name='entry_ids[]']:checked").length;
  }

  // Excluding a row no longer force-unchecks the rule checkbox: excluding one
  // outlier is exactly the case where the user still wants the rule, and the
  // old behavior was a silent one-way door.
  entrySelectionChanged() {
    this.refreshApplyState();
  }

  toggleRuleDetails() {
    if (!this.hasRuleDetailsTarget || !this.hasCreateRuleCheckboxTarget) return;
    const enabled = this.createRuleCheckboxTarget.checked;
    this.ruleDetailsTarget.classList.toggle("opacity-50", !enabled);
    if (this.hasFilterInputTarget) {
      this.filterInputTarget.disabled = !enabled;
    }
    this.refreshApplyState();
  }

  confirmFilterEdit(event) {
    event.preventDefault();
    this.previewRule(event);
  }

  previewRule(event) {
    const value = event.target.value.trim();
    if (!value) return;
    this.groupingKeyHiddenTarget.value = value;
    this._doPreviewRule(value);
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
        .then(() => this.refreshApplyState())
        .catch((err) => console.error("Rule preview failed:", err));
    }, 300);
  }

  assignEntry(event) {
    const select = event.target;
    const categoryId = select.value;
    if (!categoryId) return;

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
      .then(() => this.refreshApplyState())
      .catch((err) => {
        console.error("Entry assignment failed:", err);
        select.value = "";
      });
  }
}
