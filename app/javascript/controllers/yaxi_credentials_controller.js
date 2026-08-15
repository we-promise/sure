import { Controller } from "@hotwired/stimulus";

export default class extends Controller {
  static targets = ["bankName", "advice", "userIdGroup", "userId", "passwordGroup", "password"];

  selectBank(event) {
    this.bank = event.detail.bank;
    this.bankNameTarget.textContent = this.bank.displayName;
    this.adviceTarget.textContent = this.bank.advice || "";

    const credentials = this.bank.credentials || {};
    const models = Array.isArray(credentials)
      ? credentials.map((value) => value.toString().toLowerCase())
      : Object.entries(credentials).filter(([, enabled]) => enabled).map(([key]) => key.toLowerCase());
    this.userIdGroupTarget.classList.toggle("hidden", !this.needsUserId(models));
    this.passwordGroupTarget.classList.toggle("hidden", !models.includes("full"));
    this.userIdTarget.labels[0].textContent = this.bank.userId || this.userIdTarget.labels[0].dataset.defaultLabel;
    this.passwordTarget.labels[0].textContent = this.bank.password || this.passwordTarget.labels[0].dataset.defaultLabel;
    this.element.classList.remove("hidden");
    this.element.scrollIntoView({ behavior: "smooth", block: "start" });
  }

  submit(event) {
    event.preventDefault();
    if (!this.bank) return;

    const credentials = { connectionId: this.bank.id };
    if (!this.userIdGroupTarget.classList.contains("hidden")) credentials.userId = this.userIdTarget.value;
    if (!this.passwordGroupTarget.classList.contains("hidden")) credentials.password = this.passwordTarget.value;
    this.dispatch("submit", { detail: { credentials, connectionInfo: this.bank }, prefix: "yaxi-credentials" });
    this.passwordTarget.value = "";
  }

  needsUserId(models) {
    return models.includes("full") || models.includes("userid") || models.includes("user_id");
  }
}
