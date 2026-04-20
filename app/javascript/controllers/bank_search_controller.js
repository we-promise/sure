import { Controller } from "@hotwired/stimulus";

export default class extends Controller {
  static targets = ["input", "item", "emptyState"];

  filter() {
    const query = this.inputTarget.value.toLocaleLowerCase().trim();
    let visibleCount = 0;

    this.itemTargets.forEach(item => {
      const name = item.dataset.bankName?.toLocaleLowerCase() ?? "";
      const match = name.includes(query);
      item.style.display = match ? "" : "none";
      if (match) visibleCount++;
    });

    this.emptyStateTarget.classList.toggle("hidden", visibleCount > 0);
  }
}
