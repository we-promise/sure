import { Controller } from "@hotwired/stimulus";

// Connects to data-controller="transfer-match"
export default class extends Controller {
  static targets = ["newSelect", "existingSelect", "scheduledLoanPaymentSelect"];

  connect() {
    this.updateView(this.element.querySelector("select").value);
  }

  update(event) {
    this.updateView(event.target.value);
  }

  updateView(value) {
    if (this.hasNewSelectTarget) {
      this.newSelectTarget.classList.toggle("hidden", value !== "new");
    }

    if (this.hasExistingSelectTarget) {
      this.existingSelectTarget.classList.toggle("hidden", value !== "existing");
    }

    if (this.hasScheduledLoanPaymentSelectTarget) {
      this.scheduledLoanPaymentSelectTarget.classList.toggle("hidden", value !== "scheduled_loan_payment");
    }
  }
}
