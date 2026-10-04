import { Controller } from "@hotwired/stimulus";
import { cashFlowChartData } from "utils/cash_flow_chart_data";

// One request supplies the inline and expanded renderers. No persistent browser
// cache: Turbo snapshots must not retain a prior session's financial graph.
export default class extends Controller {
  static targets = [
    "chart",
    "loading",
    "error",
    "empty",
    "content",
    "groupBySegment",
  ];
  static values = {
    url: String,
    groupBy: { type: String, default: "category" },
  };

  connect() {
    this.load();
  }

  // Switches the graph between flows by category and through each account.
  // The choice is saved to the user's dashboard preferences; the graph is
  // refetched straight away whether or not that save succeeds.
  groupBy(event) {
    const groupBy = event.currentTarget.dataset.groupBy;
    if (groupBy === this.groupByValue) return;

    this.groupByValue = groupBy;
    this.#syncGroupBySegments();
    this.#saveGroupBy(groupBy);
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
    this.show("loading");
  }

  async load() {
    this.clear();
    const request = new AbortController();
    this.request = request;
    try {
      const url = new URL(this.urlValue, window.location.origin);
      url.searchParams.set("group_by", this.groupByValue);
      const response = await fetch(url, {
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
      this.show(data.links.length ? "content" : "empty", data);
    } catch {
      if (this.request === request) this.show("error");
    }
  }

  #syncGroupBySegments() {
    this.groupBySegmentTargets.forEach((segment) => {
      const active = segment.dataset.groupBy === this.groupByValue;
      segment.classList.toggle("segmented-control__segment--active", active);
      segment.setAttribute("aria-pressed", active ? "true" : "false");
    });
  }

  #saveGroupBy(groupBy) {
    const csrfToken = document.querySelector(
      'meta[name="csrf-token"]',
    )?.content;
    fetch("/dashboard/preferences", {
      method: "PATCH",
      headers: {
        "Content-Type": "application/json",
        "X-CSRF-Token": csrfToken,
      },
      body: JSON.stringify({
        preferences: { cashflow_sankey_group_by: groupBy },
      }),
    }).catch(() => {
      // The chart already shows the new grouping; only the default is lost.
    });
  }

  show(state, graph = null) {
    for (const name of ["loading", "error", "empty", "content"]) {
      this[`${name}Target`].hidden = name !== state;
    }
    this.dispatch("state", {
      detail: { state, ready: state === "content", graph },
    });
  }
}
