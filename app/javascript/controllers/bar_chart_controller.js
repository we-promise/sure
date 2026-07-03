import { Controller } from "@hotwired/stimulus";
import * as d3 from "d3";
import { CHART_TOOLTIP_CLASSES } from "utils/chart_tooltip";

// Minimal categorical bar chart used by the dashboard "money flow" widget —
// one bar per month, with the selected month highlighted. Modeled after
// time_series_chart_controller's lifecycle (install/teardown, ResizeObserver,
// turbo:load reinstall) but with scaleBand/scaleLinear instead of a line.
export default class extends Controller {
  static values = {
    data: Array,
    currency: { type: String, default: "USD" },
  };

  _resizeObserver = null;

  connect() {
    this._install();
    document.addEventListener("turbo:load", this._reinstall);
    this._resizeObserver = new ResizeObserver(() => this._reinstall());
    this._resizeObserver.observe(this.element);
  }

  disconnect() {
    this._teardown();
    document.removeEventListener("turbo:load", this._reinstall);
    this._resizeObserver?.disconnect();
  }

  _reinstall = () => {
    this._teardown();
    this._install();
  };

  _teardown() {
    d3.select(this.element).selectAll("*").remove();
  }

  _install() {
    const width = this.element.clientWidth;
    const height = this.element.clientHeight;
    const data = this.dataValue || [];

    if (width < 50 || height < 50 || data.length === 0) return;

    const margin = { top: 16, right: 4, bottom: 24, left: 4 };
    const innerWidth = width - margin.left - margin.right;
    const innerHeight = height - margin.top - margin.bottom;

    const svg = d3
      .select(this.element)
      .append("svg")
      .attr("width", width)
      .attr("height", height)
      .attr("viewBox", [0, 0, width, height]);

    const group = svg
      .append("g")
      .attr("transform", `translate(${margin.left},${margin.top})`);

    const x = d3
      .scaleBand()
      .domain(data.map((d) => d.label))
      .range([0, innerWidth])
      .padding(0.4);

    const maxValue = d3.max(data, (d) => d.value) || 1;
    const y = d3.scaleLinear().domain([0, maxValue]).nice().range([innerHeight, 0]);

    const tooltip = d3
      .select(this.element)
      .append("div")
      .attr("class", `${CHART_TOOLTIP_CLASSES} opacity-0 top-0`);

    group
      .selectAll("rect")
      .data(data)
      .join("rect")
      .attr("x", (d) => x(d.label))
      .attr("y", (d) => y(d.value))
      .attr("width", x.bandwidth())
      .attr("height", (d) => innerHeight - y(d.value))
      .attr("rx", 4)
      .attr("fill", (d) => (d.highlighted ? "var(--color-success)" : "var(--color-gray-300)"))
      .on("mousemove", (event, d) => {
        const [xPos, yPos] = d3.pointer(event, this.element);

        tooltip
          .html(this._tooltipTemplate(d))
          .style("opacity", 1)
          .style("left", `${xPos + 12}px`)
          .style("top", `${yPos - 10}px`);
      })
      .on("mouseleave", () => {
        tooltip.style("opacity", 0);
      });

    group
      .append("g")
      .attr("transform", `translate(0,${innerHeight})`)
      .call(d3.axisBottom(x).tickSize(0))
      .call((g) => g.select(".domain").remove())
      .selectAll("text")
      .attr("class", (_d, i) => (data[i].highlighted ? "text-primary" : "text-secondary"))
      .style("font-size", "12px")
      .style("font-weight", (_d, i) => (data[i].highlighted ? 600 : 500));
  }

  _tooltipTemplate(d) {
    return `
      <div class="text-xs text-secondary mb-1">${d.label}</div>
      <div class="text-primary font-medium tabular-nums">${this._formatCurrency(d.value)}</div>
    `;
  }

  _formatCurrency(value) {
    try {
      return new Intl.NumberFormat(undefined, {
        style: "currency",
        currency: this.currencyValue,
        maximumFractionDigits: 0,
      }).format(value);
    } catch {
      return value;
    }
  }
}
