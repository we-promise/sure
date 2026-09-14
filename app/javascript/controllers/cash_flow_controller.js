import { Controller } from "@hotwired/stimulus";
import { cashFlowChartData } from "utils/cash_flow_chart_data";

// One request supplies the inline and expanded renderers. No persistent browser
// cache: Turbo snapshots must not retain a prior session's financial graph.
export default class extends Controller {
  static targets = ["chart", "loading", "error", "empty", "content"];
  static values = { url: String };

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
      chart.removeAttribute("data-sankey-chart-data-value");
      chart.querySelectorAll("svg").forEach((svg) => svg.remove());
    });
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
        chart.setAttribute("data-sankey-chart-currency-value", body.currency);
        chart.setAttribute(
          "data-sankey-chart-data-value",
          JSON.stringify(data),
        );
      });
      this.show(data.links.length ? "content" : "empty");
    } catch {
      if (this.request === request) this.show("error");
    }
  }

  show(state) {
    for (const name of ["loading", "error", "empty", "content"]) {
      this[`${name}Target`].hidden = name !== state;
    }
    this.dispatch("state", { detail: { ready: state === "content" } });
  }
}
