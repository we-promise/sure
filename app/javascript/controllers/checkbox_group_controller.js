import { Controller } from "@hotwired/stimulus";

// A master toggle for a column of toggles. Mark each toggle in the column
// with data-checkbox-group="name" and the master with
// data-checkbox-group-master="name". Switching the master switches every
// enabled member to match, and the master stays on only while every member
// is on.
export default class extends Controller {
  connect() {
    this.sync();
  }

  toggleAll({ target, params: { group } }) {
    for (const checkbox of this.members(group)) {
      checkbox.checked = target.checked;
    }
  }

  sync() {
    for (const master of this.element.querySelectorAll(
      "[data-checkbox-group-master]",
    )) {
      const members = this.members(master.dataset.checkboxGroupMaster);
      master.checked =
        members.length > 0 && members.every((checkbox) => checkbox.checked);
    }
  }

  members(group) {
    const selector = `input[type=checkbox][data-checkbox-group="${group}"]`;
    return [...this.element.querySelectorAll(selector)].filter(
      (checkbox) => !checkbox.disabled,
    );
  }
}
