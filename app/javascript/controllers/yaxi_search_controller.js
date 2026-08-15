import { Controller } from "@hotwired/stimulus";
import { RoutexClient } from "routex-client";

export default class extends Controller {
  static targets = ["input", "results", "choiceTemplate"];
  static values = { baseUrl: String, ticket: String, messages: Object };

  connect() {
    this.client = new RoutexClient({ url: new URL(this.baseUrlValue) });
  }

  async search(event) {
    event.preventDefault();
    const query = this.inputTarget.value.trim();
    if (!query) return;

    this.dispatchStatus("busy", this.message("searching"));
    try {
      this.banks = await this.client.search({
        ticket: this.ticketValue,
        filters: query.split(/\s+/).map((term) => ({ term })),
        ibanDetection: true,
        limit: 20,
      });
      this.renderBanks();
      this.dispatchStatus("clear");
    } catch {
      this.dispatchStatus("error", this.message("request_failed"));
    }
  }

  select(event) {
    const bank = this.banks[event.params.bankIndex];
    if (bank) this.dispatch("selected", { detail: { bank }, prefix: "yaxi-search" });
  }

  renderBanks() {
    this.resultsTarget.replaceChildren();
    if (this.banks.length === 0) {
      const empty = document.createElement("p");
      empty.className = "text-sm text-secondary";
      empty.textContent = this.message("no_bank");
      this.resultsTarget.append(empty);
      return;
    }

    for (const [index, bank] of this.banks.entries()) {
      const button = this.choiceTemplateTarget.content.firstElementChild.cloneNode(true);
      button.textContent = bank.displayName;
      button.dataset.action = "yaxi-search#select";
      button.dataset.yaxiSearchBankIndexParam = index;
      this.resultsTarget.append(button);
    }
  }

  dispatchStatus(kind, value) {
    window.dispatchEvent(new CustomEvent(`yaxi-status:${kind}`, { detail: { value } }));
  }

  message(key) {
    return this.messagesValue[key] || key;
  }
}
