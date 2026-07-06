import { Controller } from "@hotwired/stimulus";
import * as d3 from "d3";
import { CHART_TOOLTIP_CLASSES } from "utils/chart_tooltip";

// Grouped bar chart used by the dashboard "money flow" widget — each month
// shows an expense bar (red) and an income bar (green) side by side.
// Modeled after time_series_chart_controller's lifecycle (install/teardown,
// ResizeObserver, turbo:load reinstall, page-relative tooltip positioning)
// but with scaleBand/scaleLinear instead of a line.
export default class extends Controller {
  static values = {
    data: Array,
    currency: { type: String, default: "USD" },
    incomeLabel: { type: String, default: "Income" },
    expenseLabel: { type: String, default: "Expenses" },
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

    const series = ["income", "expense"];
    const seriesColor = { expense: "var(--color-gray-400)", income: "var(--color-success)" };

    const x0 = d3
      .scaleBand()
      .domain(data.map((d) => d.label))
      .range([0, innerWidth])
      .padding(0.3);

    const x1 = d3.scaleBand().domain(series).range([0, x0.bandwidth()]).padding(0.15);

    const maxValue = d3.max(data, (d) => Math.max(d.income, d.expense)) || 1;
    const y = d3.scaleLinear().domain([0, maxValue * 1.1]).range([innerHeight, 0]);
    // Floor tiny-but-nonzero bars (e.g. an in-progress month) at 2px so they stay visible.
    const barHeight = (v) => (v > 0 ? Math.max(2, innerHeight - y(v)) : 0);

    const tooltip = d3
      .select(this.element)
      .append("div")
      .attr("class", `${CHART_TOOLTIP_CLASSES} opacity-0 top-0`);

    const showTooltip = (event, month, key) => {
      const estimatedTooltipWidth = 200;
      const pageWidth = document.body.clientWidth;
      const tooltipX = event.pageX + 10;
      const overflowX = tooltipX + estimatedTooltipWidth - pageWidth;
      const adjustedX = overflowX > 0 ? event.pageX - overflowX - 20 : tooltipX;

      tooltip
        .html(this._tooltipTemplate(month, key))
        .style("opacity", 1)
        .style("left", `${adjustedX}px`)
        .style("top", `${event.pageY - 10}px`);
    };

    const hideTooltip = () => tooltip.style("opacity", 0);

    const monthGroups = group
      .selectAll("g.month")
      .data(data)
      .join("g")
      .attr("class", "month")
      .attr("transform", (d) => `translate(${x0(d.label)},0)`);

    monthGroups
      .selectAll("rect")
      .data((d) => series.map((key) => ({ key, value: d[key], month: d })))
      .join("rect")
      .attr("x", (d) => x1(d.key))
      .attr("y", (d) => innerHeight - barHeight(d.value))
      .attr("width", x1.bandwidth())
      .attr("height", (d) => barHeight(d.value))
      .attr("rx", 3)
      .attr("fill", (d) => seriesColor[d.key])
      // In-progress month (period capped at today) reads as provisional.
      .attr("fill-opacity", (d) => (d.month.partial ? 0.5 : 1))
      .on("mousemove", (event, d) => showTooltip(event, d.month, d.key))
      .on("mouseleave", hideTooltip);

    group
      .append("g")
      .attr("transform", `translate(0,${innerHeight})`)
      .call(d3.axisBottom(x0).tickSize(0))
      .call((g) => g.select(".domain").remove())
      .selectAll("text")
      .attr("class", (_d, i) => (data[i].highlighted ? "text-primary fill-current" : "text-secondary fill-current"))
      .style("font-size", "12px")
      .style("font-weight", (_d, i) => (data[i].highlighted ? 600 : 500));
  }

  _tooltipTemplate(month, key) {
    const label = key === "income" ? this.incomeLabelValue : this.expenseLabelValue;
    const color = key === "income" ? "var(--color-success)" : "var(--color-destructive)";

    return `
      <div class="text-xs text-secondary mb-1">${month.label}</div>
      <div class="flex items-center gap-1.5 text-primary font-medium tabular-nums">
        <span class="inline-block w-2 h-2 rounded-full" style="background-color: ${color};"></span>
        ${label}: ${this._formatCurrency(month[key])}
      </div>
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
