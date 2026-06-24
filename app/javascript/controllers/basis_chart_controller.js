import { Controller } from "@hotwired/stimulus";
import * as d3 from "d3";
import {
  CHART_TOOLTIP_CLASSES,
  CHART_TOOLTIP_CONTEXT_CLASSES,
  CHART_TOOLTIP_VALUE_CLASSES,
} from "utils/chart_tooltip";

// Dedicated controller for the Basis page. Draws a single line whose value at
// each timestamp is the sum of the leg values whose toggle is enabled, and
// recomputes that line client-side as toggles change — no server round-trip.
//
// Intentionally NOT built on time_series_chart_controller: that controller
// expects one trend-colored series and has no concept of four independent
// columns, client-side recomposition, or a multi-value tooltip.
export default class extends Controller {
  static targets = ["chart", "selectedTotal", "legTotal", "toggle"];
  static values = {
    payload: Object,
    labels: Object,
    currency: { type: String, default: "USD" },
    locale: { type: String, default: "en" },
  };

  static LEGS = ["spot", "short", "funding", "rewards"];

  connect() {
    if (typeof ResizeObserver !== "undefined") {
      this._resizeObserver = new ResizeObserver(() => this._draw());
      this._resizeObserver.observe(this.chartTarget);
    }

    if (typeof MutationObserver !== "undefined") {
      this._themeObserver = new MutationObserver((mutations) => {
        if (mutations.some((m) => m.attributeName === "data-theme")) this._draw();
      });
      this._themeObserver.observe(document.documentElement, { attributes: true });
    }

    this._updateKpis();
    this._draw();
  }

  disconnect() {
    this._resizeObserver?.disconnect();
    this._themeObserver?.disconnect();
    this._tooltip?.remove();
  }

  // Action bound to each toggle's `change` event.
  redraw() {
    this._updateKpis();
    this._draw();
  }

  get _enabledLegs() {
    const enabled = {};
    for (const leg of this.constructor.LEGS) {
      enabled[leg] = true;
    }
    for (const toggle of this.toggleTargets) {
      enabled[toggle.dataset.leg] = toggle.checked;
    }
    return enabled;
  }

  _selectedTotal(point, enabled) {
    return this.constructor.LEGS.reduce(
      (sum, leg) => sum + (enabled[leg] ? point[leg] || 0 : 0),
      0,
    );
  }

  _formatCurrency(value) {
    try {
      return new Intl.NumberFormat(this.localeValue, {
        style: "currency",
        currency: this.currencyValue,
      }).format(value);
    } catch (_e) {
      return `${this.currencyValue} ${value.toFixed(2)}`;
    }
  }

  // Keep the top "Selected total" KPI and per-leg KPIs in sync with the toggles.
  _updateKpis() {
    const totals = this.payloadValue.totals || {};
    const enabled = this._enabledLegs;
    const selected = this._selectedTotal(totals, enabled);

    if (this.hasSelectedTotalTarget) {
      this.selectedTotalTarget.textContent = this._formatCurrency(selected);
    }

    this.legTotalTargets.forEach((el) => {
      const leg = el.dataset.leg;
      el.textContent = this._formatCurrency(totals[leg] || 0);
      el.classList.toggle("opacity-40", !enabled[leg]);
    });
  }

  _draw() {
    const root = this.chartTarget;
    root.innerHTML = "";

    const points = (this.payloadValue.points || []).map((p) => ({
      ...p,
      dateObj: this._parseLocalDate(p.date),
    }));
    if (points.length === 0) return;

    const width = root.clientWidth || 720;
    const height = root.clientHeight || 320;
    if (width <= 0 || height <= 0) return;

    const isDark = document.documentElement.getAttribute("data-theme") === "dark";
    const textPrimary = isDark ? "#ffffff" : "#171717";
    const textSecondary = isDark ? "#cfcfcf" : "#737373";
    const borderSubdued = isDark ? "rgba(255,255,255,0.15)" : "rgba(0,0,0,0.10)";
    const lineColor = isDark ? "#ffffff" : "#171717";

    const enabled = this._enabledLegs;
    const series = points.map((p) => ({
      date: p.dateObj,
      value: this._selectedTotal(p, enabled),
      point: p,
    }));

    const yAxisVisible = width - 16 - 24 >= 320;
    const margin = { top: 16, right: 24, bottom: 28, left: yAxisVisible ? 56 : 16 };
    const innerWidth = width - margin.left - margin.right;
    const innerHeight = height - margin.top - margin.bottom;

    const xExtent = d3.extent(series, (d) => d.date);
    // A single point would collapse the time scale; pad the domain a day either
    // side so the dot renders centered.
    const x = d3
      .scaleTime()
      .domain(
        xExtent[0].getTime() === xExtent[1].getTime()
          ? [d3.timeDay.offset(xExtent[0], -1), d3.timeDay.offset(xExtent[1], 1)]
          : xExtent,
      )
      .range([margin.left, margin.left + innerWidth]);

    const yExtent = d3.extent(series, (d) => d.value);
    const yPad = Math.max((yExtent[1] - yExtent[0]) * 0.1, 1);
    const y = d3
      .scaleLinear()
      .domain([yExtent[0] - yPad, yExtent[1] + yPad])
      .range([margin.top + innerHeight, margin.top]);

    const svg = d3
      .select(root)
      .append("svg")
      .attr("width", width)
      .attr("height", height)
      .attr("viewBox", `0 0 ${width} ${height}`)
      .attr("role", "img")
      .attr("aria-label", "Basis combined leg equity");

    // Y gridlines + labels
    if (yAxisVisible) {
      const yTicks = y.ticks(4);
      svg
        .append("g")
        .selectAll("line")
        .data(yTicks)
        .join("line")
        .attr("x1", margin.left)
        .attr("x2", margin.left + innerWidth)
        .attr("y1", (d) => y(d))
        .attr("y2", (d) => y(d))
        .attr("stroke", borderSubdued)
        .attr("stroke-width", 1);

      svg
        .append("g")
        .selectAll("text")
        .data(yTicks)
        .join("text")
        .attr("x", margin.left - 8)
        .attr("y", (d) => y(d))
        .attr("dy", "0.32em")
        .attr("text-anchor", "end")
        .attr("font-size", 11)
        .attr("fill", textSecondary)
        .text((d) => this._formatCurrency(d));
    }

    // X axis labels (first / middle / last)
    const xLabelTicks =
      series.length <= 2 ? series : [series[0], series[Math.floor(series.length / 2)], series[series.length - 1]];
    svg
      .append("g")
      .selectAll("text")
      .data(xLabelTicks)
      .join("text")
      .attr("x", (d) => x(d.date))
      .attr("y", margin.top + innerHeight + 18)
      .attr("text-anchor", "middle")
      .attr("font-size", 11)
      .attr("fill", textSecondary)
      .text((d) => d3.timeFormat("%b %d")(d.date));

    const line = d3
      .line()
      .x((d) => x(d.date))
      .y((d) => y(d.value))
      .curve(d3.curveMonotoneX);

    svg
      .append("path")
      .datum(series)
      .attr("fill", "none")
      .attr("stroke", lineColor)
      .attr("stroke-width", 2)
      .attr("stroke-linejoin", "round")
      .attr("stroke-linecap", "round")
      .attr("d", line);

    // Single-point series renders a dot so it doesn't disappear.
    if (series.length === 1) {
      svg
        .append("circle")
        .attr("cx", x(series[0].date))
        .attr("cy", y(series[0].value))
        .attr("r", 4)
        .attr("fill", lineColor);
    }

    this._installTooltip(svg, series, x, y, margin, innerWidth, innerHeight, lineColor, enabled);
  }

  _installTooltip(svg, series, x, y, margin, innerWidth, innerHeight, lineColor, enabled) {
    if (!this._tooltip) {
      this._tooltip = document.createElement("div");
      this._tooltip.className = CHART_TOOLTIP_CLASSES;
      this._tooltip.style.display = "none";
      this.chartTarget.appendChild(this._tooltip);
    }
    const tooltip = this._tooltip;

    const crosshair = svg
      .append("line")
      .attr("y1", margin.top)
      .attr("y2", margin.top + innerHeight)
      .attr("stroke", lineColor)
      .attr("stroke-width", 1)
      .attr("stroke-dasharray", "3,3")
      .style("opacity", 0);

    const dot = svg
      .append("circle")
      .attr("r", 4)
      .attr("fill", lineColor)
      .style("opacity", 0);

    const bisect = d3.bisector((d) => d.date).center;

    svg
      .append("rect")
      .attr("x", margin.left)
      .attr("y", margin.top)
      .attr("width", Math.max(innerWidth, 0))
      .attr("height", Math.max(innerHeight, 0))
      .attr("fill", "transparent")
      .style("cursor", "crosshair")
      .on("pointermove", (event) => {
        const [mx] = d3.pointer(event);
        const date = x.invert(mx);
        const i = bisect(series, date);
        const d = series[i];
        if (!d) return;

        crosshair.attr("x1", x(d.date)).attr("x2", x(d.date)).style("opacity", 1);
        dot.attr("cx", x(d.date)).attr("cy", y(d.value)).style("opacity", 1);

        tooltip.innerHTML = this._tooltipHtml(d.point, enabled, d.value);
        tooltip.style.display = "block";

        const rect = this.chartTarget.getBoundingClientRect();
        const tipWidth = tooltip.offsetWidth;
        let left = x(d.date) + 12;
        if (left + tipWidth > rect.width) left = x(d.date) - tipWidth - 12;
        tooltip.style.left = `${left}px`;
        tooltip.style.top = `${margin.top}px`;
      })
      .on("pointerleave", () => {
        crosshair.style("opacity", 0);
        dot.style("opacity", 0);
        tooltip.style.display = "none";
      });
  }

  _tooltipHtml(point, enabled, selectedTotal) {
    const row = (label, value, on) =>
      `<div class="flex items-center justify-between gap-4 ${on ? "" : "opacity-40"}">
         <span class="text-secondary">${label}</span>
         <span class="${CHART_TOOLTIP_VALUE_CLASSES}">${this._formatCurrency(value)}</span>
       </div>`;

    const labels = this.labelsValue || {};
    return `
      <div class="${CHART_TOOLTIP_CONTEXT_CLASSES}">${point.date_formatted || point.date}</div>
      <div class="space-y-0.5">
        ${row(labels.spot || "weETH spot", point.spot, enabled.spot)}
        ${row(labels.short || "Perps short", point.short, enabled.short)}
        ${row(labels.funding || "Funding", point.funding, enabled.funding)}
        ${row(labels.rewards || "Rewards", point.rewards, enabled.rewards)}
        <div class="flex items-center justify-between gap-4 pt-1 mt-1 border-t border-secondary">
          <span class="text-primary font-medium">${labels.combined || "Selected total"}</span>
          <span class="${CHART_TOOLTIP_VALUE_CLASSES} text-primary">${this._formatCurrency(selectedTotal)}</span>
        </div>
      </div>`;
  }

  _parseLocalDate(s) {
    if (!s) return null;
    const [yr, mo, da] = s.split("-").map(Number);
    return new Date(yr, mo - 1, da);
  }
}
