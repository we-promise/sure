import { Controller } from "@hotwired/stimulus";

// Connects to data-controller="bulk-select"
export default class extends Controller {
  static targets = [
    "row",
    "group",
    "selectionBar",
    "selectionBarText",
    "bulkEditDrawerHeader",
    "duplicateLink",
  ];
  static values = {
    singularLabel: String,
    pluralLabel: String,
    selectedLabel: { type: String, default: "selected" },
    editLabel: { type: String, default: "Edit" },
    selectedIds: { type: Array, default: [] },
  };

  connect() {
    document.addEventListener("turbo:load", this._updateView);

    this._updateView();
  }

  disconnect() {
    document.removeEventListener("turbo:load", this._updateView);
  }

  bulkEditDrawerHeaderTargetConnected(element) {
    const headingTextEl = element.querySelector("h2");
    headingTextEl.innerText = `${this.editLabelValue} ${
      this.selectedIdsValue.length
    } ${this._pluralizedResourceName()}`;
  }

  submitBulkRequest(e) {
    const form = e.target.closest("form");
    const scope = e.params.scope;
    const param = e.params.param || "entry_ids";
    this._addHiddenFormInputsForSelectedIds(
      form,
      `${scope}[${param}][]`,
      this.selectedIdsValue,
    );
    form.requestSubmit();
  }

  togglePageSelection(e) {
    if (e.target.checked) {
      this._selectAll();
    } else {
      this.deselectAll();
    }
  }

  toggleGroupSelection(e) {
    const group = this.groupTargets.find((group) => group.contains(e.target));

    this._rowsForGroup(group).forEach((row) => {
      if (e.target.checked) {
        this._addToSelection(row.dataset.id);
      } else {
        this._removeFromSelection(row.dataset.id);
      }
    });
  }

  toggleRowSelection(e) {
    const checkbox = e.currentTarget.matches("input[type='checkbox']")
      ? e.currentTarget
      : e.currentTarget.querySelector("input[type='checkbox']");

    if (!checkbox || checkbox.disabled) return;

    if (e.currentTarget !== checkbox) {
      if (e.target.matches("input[type='checkbox']")) {
        // The browser has already toggled the checkbox.
      } else if (
        e.target.closest("a, button, input, select, textarea, label")
      ) {
        return;
      } else {
        checkbox.checked = !checkbox.checked;
      }
    }

    if (checkbox.checked) {
      this._addToSelection(checkbox.dataset.id);
    } else {
      this._removeFromSelection(checkbox.dataset.id);
    }
  }

  deselectAll() {
    this.selectedIdsValue = [];
    this.element.querySelectorAll('input[type="checkbox"]').forEach((el) => {
      el.checked = false;
    });
  }

  selectedIdsValueChanged() {
    this._updateView();
  }

  _addHiddenFormInputsForSelectedIds(form, paramName, transactionIds) {
    this._resetFormInputs(form, paramName);

    transactionIds.forEach((id) => {
      const input = document.createElement("input");
      input.type = "hidden";
      input.name = paramName;
      input.value = id;
      input.dataset.bulkSelectGenerated = "true";
      form.appendChild(input);
    });
  }

  _resetFormInputs(form, paramName) {
    const existingInputs = form.querySelectorAll(
      `input[data-bulk-select-generated='true'][name='${paramName}']`,
    );
    existingInputs.forEach((input) => input.remove());
  }

  _rowsForGroup(group) {
    return this.rowTargets.filter(
      (row) => group.contains(row) && !row.disabled,
    );
  }

  _addToSelection(idToAdd) {
    this.selectedIdsValue = Array.from(
      new Set([...this.selectedIdsValue, idToAdd]),
    );
  }

  _removeFromSelection(idToRemove) {
    this.selectedIdsValue = this.selectedIdsValue.filter(
      (id) => id !== idToRemove,
    );
  }

  _selectAll() {
    this.selectedIdsValue = this.rowTargets
      .filter((t) => !t.disabled)
      .map((t) => t.dataset.id);
  }

  _updateView = () => {
    this._updateSelectionBar();
    this._updateGroups();
    this._updateRows();
  };

  _updateSelectionBar() {
    const count = this.selectedIdsValue.length;
    this.selectionBarTextTarget.innerText = `${count} ${this._pluralizedResourceName()} ${this.selectedLabelValue}`;
    this.selectionBarTarget.classList.toggle("hidden", count === 0);
    this.selectionBarTarget.querySelector("input[type='checkbox']").checked =
      count > 0;

    if (this.hasDuplicateLinkTarget) {
      const selectedRow = this._selectedRow();
      const canDuplicate =
        count === 1 && selectedRow?.dataset.entryType === "Transaction";

      this.duplicateLinkTarget.classList.toggle("hidden", !canDuplicate);

      if (canDuplicate) {
        const url = new URL(
          this.duplicateLinkTarget.href,
          window.location.origin,
        );
        url.searchParams.set("duplicate_entry_id", this.selectedIdsValue[0]);
        this.duplicateLinkTarget.href = url.toString();
      }
    }
  }

  _pluralizedResourceName() {
    if (this.selectedIdsValue.length === 1) {
      return this.singularLabelValue;
    }

    return this.pluralLabelValue;
  }

  _selectedRow() {
    if (this.selectedIdsValue.length !== 1) return null;

    return this.rowTargets.find(
      (row) => row.dataset.id === this.selectedIdsValue[0],
    );
  }

  _updateGroups() {
    this.groupTargets.forEach((group) => {
      const rows = this.rowTargets.filter(
        (row) => group.contains(row) && !row.disabled,
      );
      const groupSelected =
        rows.length > 0 &&
        rows.every((row) => this.selectedIdsValue.includes(row.dataset.id));
      group.querySelector("input[type='checkbox']").checked = groupSelected;
    });
  }

  _updateRows() {
    this.rowTargets.forEach((row) => {
      const selected = this.selectedIdsValue.includes(row.dataset.id);
      row.checked = selected;

      const rowElement = row.closest("tr");
      rowElement?.classList.toggle("bg-surface-hover", selected);
      rowElement?.setAttribute("aria-selected", selected.toString());
    });
  }
}
