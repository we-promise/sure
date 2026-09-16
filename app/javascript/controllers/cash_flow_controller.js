import { Controller } from "@hotwired/stimulus";
import {
  cashFlowChartData,
  formatCashFlowCurrency,
} from "utils/cash_flow_chart_data";

// Placeholder the server-rendered translation puts where the amount belongs,
// so word order stays correct per locale. Replaced with the real formatted
// amount once the async response tells us what it is.
const NOTE_AMOUNT_PLACEHOLDER = "@@AMOUNT@@";

// One request supplies the inline and expanded renderers. No persistent browser
// cache: Turbo snapshots must not retain a prior session's financial graph.
export default class extends Controller {
  static targets = [
    "chart",
    "loading",
    "error",
    "empty",
    "content",
    "investmentNote",
  ];
  static values = { url: String, noteTemplate: String };

  connect() {
    this.load();
  }

  disconnect() {
    this.clear();
  }

  clear() {
    this.request?.abort();
    this.request = null;
    this.chartTargets.forEach((chart) => {
      chart.removeAttribute("data-preview-sankey-chart-data-value");
      chart.querySelectorAll("svg").forEach((svg) => svg.remove());
    });
    if (this.hasInvestmentNoteTarget) this.investmentNoteTarget.hidden = true;
    this.show("loading");
  }

  async load() {
    this.clear();
    const request = new AbortController();
    this.request = request;
    try {
      const response = await fetch(this.urlValue, {
        headers: { Accept: "application/json" },
        credentials: "same-origin",
        cache: "no-store",
        signal: request.signal,
      });
      if (!response.ok) throw new Error("Cash flow unavailable");
      const body = await response.json();
      const data = cashFlowChartData(body);
      if (this.request !== request) return;
      this.chartTargets.forEach((chart) => {
        chart.setAttribute(
          "data-preview-sankey-chart-currency-value",
          body.currency,
        );
        chart.setAttribute(
          "data-preview-sankey-chart-data-value",
          JSON.stringify(data),
        );
      });
      this.renderInvestmentNote(body);
      this.show(data.links.length ? "content" : "empty");
    } catch {
      if (this.request === request) this.show("error");
    }
  }

  // Money that left an account but isn't spending -- it moved into an
  // investment/crypto account, so it's called out separately rather than
  // silently dropped from the chart above (see Transaction::NON_OPERATING_KINDS).
  renderInvestmentNote(body) {
    if (!this.hasInvestmentNoteTarget) return;
    const raw = body.investment_contributions;
    const amount =
      typeof raw === "string" && /^\d+(\.\d+)?$/.test(raw) ? Number(raw) : 0;
    if (amount <= 0) {
      this.investmentNoteTarget.hidden = true;
      return;
    }
    const formatted = formatCashFlowCurrency(
      amount,
      body.currency,
      navigator.language,
    );
    this.investmentNoteTarget.textContent = this.noteTemplateValue.replace(
      NOTE_AMOUNT_PLACEHOLDER,
      formatted,
    );
    this.investmentNoteTarget.hidden = false;
  }

  show(state) {
    for (const name of ["loading", "error", "empty", "content"]) {
      this[`${name}Target`].hidden = name !== state;
    }
    this.dispatch("state", { detail: { state, ready: state === "content" } });
  }
}
