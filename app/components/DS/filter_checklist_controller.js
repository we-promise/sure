import { Controller } from "@hotwired/stimulus";

export default class extends Controller {
  static targets = ["search", "row", "checkbox", "empty"];

  search() {
    const query = this.normalize(this.searchTarget.value);
    let matches = 0;
    for (const row of this.rowTargets) {
      row.hidden = !this.normalize(row.dataset.name).includes(query);
      row.classList.toggle("hidden", row.hidden);
      if (!row.hidden) matches++;
    }
    this.emptyTarget.classList.toggle("hidden", matches > 0);
  }

  all(event) {
    event.preventDefault();
    this.checkboxTargets.forEach((checkbox) => {
      checkbox.checked = true;
    });
  }

  none(event) {
    event.preventDefault();
    this.checkboxTargets.forEach((checkbox) => {
      checkbox.checked = false;
    });
  }

  normalize(value) {
    return value
      .normalize("NFD")
      .replace(/\p{Mark}/gu, "")
      .toLowerCase();
  }
}
