import { Controller } from "@hotwired/stimulus";

export default class extends Controller {
  static targets = ["from", "to", "error", "submit", "period"];
  static values = { currentMonth: String };

  connect() {
    this.validate();
  }

  monthIndex(picker) {
    const year = Number(picker.querySelector("select[name$='_year']").value);
    const month = Number(picker.querySelector("select[name$='_month']").value);
    return year > 0 && month >= 1 && month <= 12 ? year * 12 + month - 1 : null;
  }

  validate(event) {
    if (event?.target.tagName === "SELECT") this.periodTarget.value = "custom";
    const from = this.monthIndex(this.fromTarget);
    const to = this.monthIndex(this.toTarget);
    const [year, month] = this.currentMonthValue.split("-").map(Number);
    const valid =
      from !== null &&
      to !== null &&
      from <= to &&
      to - from < 36 &&
      to <= year * 12 + month - 1;
    this.submitTarget.disabled = !valid;
    this.errorTarget.classList.toggle("hidden", valid);
    return valid;
  }

  submit(event) {
    if (!this.validate()) event.preventDefault();
  }
}
