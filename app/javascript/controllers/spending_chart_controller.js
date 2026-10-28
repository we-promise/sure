import { Controller } from "@hotwired/stimulus";
import * as d3 from "d3";
import { CHART_TOOLTIP_CLASSES } from "utils/chart_tooltip";

// Cumulative spending chart for the dashboard "spending" widget: the selected
// month's running total (green, ending today while the month is in progress)
// overlaid on the complete curves of the months it's compared with (the
// previous month in gray, older ones in their own colors), sharing one
// day-of-month axis. Lifecycle mirrors bar_chart/time_series_chart
// (install/teardown, ResizeObserver, turbo:load reinstall, page-relative
// tooltip positioning).
const CURRENT_COLOR = "var(--color-success)";
// Compared months, newest first; the server offers at most this many.
const COMPARISON_COLORS = [
  "var(--color-gray-400)",
  "var(--color-blue-500)",
  "var(--color-violet-500)",
  "var(--color-orange-500)",
  "var(--color-pink-500)",
];

export default class extends Controller {
  static values = {
    data: Object,
    currency: { type: String, default: "USD" },
    currentLabel: { type: String, default: "Current" },
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
    const {
      days = 30,
      current_days: currentDays = days,
      axis_labels: axisLabels = [],
      current = [],
      comparisons: rawComparisons = [],
    } = this.dataValue || {};
    const comparisons = rawComparisons.map((comparison, i) => ({
      ...comparison,
      color: COMPARISON_COLORS[i % COMPARISON_COLORS.length],
    }));
    const comparisonPoints = comparisons.flatMap((c) => c.series);

    const maxValue =
      d3.max([...current, ...comparisonPoints], (d) => d.value) || 0;
    if (maxValue <= 0) return;

    // With one compared month the header already names both lines.
    if (comparisons.length > 1) this._drawLegend(comparisons);

    const width = this.element.clientWidth;
    const height = this.element.clientHeight - this._legendHeight();

    // Room on the right for the axis labels ($0, $1.5K, …), like the
    // reference design; the curves run to the axis, not the card edge.
    const margin = { top: 8, right: 48, bottom: 20, left: 4 };
    const innerWidth = width - margin.left - margin.right;
    const innerHeight = height - margin.top - margin.bottom;

    // The legend must be in the DOM to be measured
    if (width < 50 || height < 50 || innerWidth <= 0 || innerHeight <= 0) {
      this._teardown();
      return;
    }

    const svg = d3
      .select(this.element)
      .append("svg")
      .attr("width", width)
      .attr("height", height)
      .attr("viewBox", [0, 0, width, height]);

    const group = svg
      .append("g")
      .attr("transform", `translate(${margin.left},${margin.top})`);

    const x = d3.scaleLinear().domain([1, days]).range([0, innerWidth]);
    const y = d3
      .scaleLinear()
      .domain([0, maxValue * 1.05])
      .nice()
      .range([innerHeight, 0]);

    this._drawGridlines(group, y, innerWidth, innerHeight);
    this._drawXAxis(group, x, days, innerHeight, axisLabels, currentDays);

    const line = d3
      .line()
      .x((d) => x(d.day))
      .y((d) => y(d.value))
      .curve(d3.curveMonotoneX);

    // Oldest month first so newer months, and the current month above all,
    // draw on top.
    for (const comparison of [...comparisons].reverse()) {
      if (comparison.series.length === 0) continue;
      group
        .append("path")
        .datum(comparison.series)
        .attr("fill", "none")
        .attr("stroke", comparison.color)
        .attr("stroke-width", 1.5)
        .attr("stroke-linejoin", "round")
        .attr("stroke-linecap", "round")
        .attr("d", line);
    }

    if (current.length > 0) {
      group
        .append("path")
        .datum(current)
        .attr("fill", "none")
        .attr("stroke", CURRENT_COLOR)
        .attr("stroke-width", 2)
        .attr("stroke-linejoin", "round")
        .attr("stroke-linecap", "round")
        .attr("d", line);

      // Endpoint dot marks "today" on the in-progress curve.
      const last = current[current.length - 1];
      group
        .append("circle")
        .attr("cx", x(last.day))
        .attr("cy", y(last.value))
        .attr("r", 3.5)
        .attr("fill", CURRENT_COLOR);
    }

    this._installTooltip(
      group,
      x,
      y,
      current,
      comparisons,
      innerWidth,
      innerHeight,
    );
  }

  _drawLegend(comparisons) {
    const legend = d3
      .select(this.element)
      .append("div")
      .attr(
        "class",
        "legend flex flex-wrap gap-x-3 gap-y-1 pb-2 text-xs text-secondary",
      );

    for (const { label, color } of [
      { label: this.currentLabelValue, color: CURRENT_COLOR },
      ...comparisons,
    ]) {
      const item = legend
        .append("span")
        .attr("class", "inline-flex items-center gap-1.5");
      item
        .append("span")
        .attr("class", "inline-block w-2 h-2 rounded-full")
        .style("background-color", color);
      item.append("span").text(label);
    }
  }

  _legendHeight() {
    return this.element.querySelector(".legend")?.offsetHeight ?? 0;
  }

  _drawGridlines(group, y, innerWidth, innerHeight) {
    const ticks = y.ticks(4);

    group
      .append("g")
      .selectAll("line")
      .data(ticks)
      .join("line")
      .attr("x1", 0)
      .attr("x2", innerWidth)
      .attr("y1", (d) => y(d))
      .attr("y2", (d) => y(d))
      .attr("stroke", "var(--color-gray-300)")
      .attr("stroke-dasharray", "4, 4")
      .attr("stroke-opacity", 0.6);

    group
      .append("g")
      .attr("transform", `translate(${innerWidth},0)`)
      .call(
        d3
          .axisRight(y)
          .tickValues(ticks)
          .tickSize(0)
          .tickPadding(8)
          .tickFormat((d) => this._formatCompact(d)),
      )
      .call((g) => g.select(".domain").remove())
      .selectAll("text")
      .attr("class", "text-secondary fill-current")
      .style("font-size", "12px")
      .style("font-weight", "500");
  }

  _drawXAxis(group, x, days, innerHeight, axisLabels, currentDays = days) {
    const mobile = !window.matchMedia("(min-width: 640px)").matches;
    const span = mobile ? Math.min(days, currentDays) : days;
    const tickDays = [...new Set([1, Math.round((1 + span) / 2), span])];

    group
      .append("g")
      .attr("transform", `translate(0,${innerHeight})`)
      .call(
        d3
          .axisBottom(x)
          .tickValues(tickDays)
          .tickSize(0)
          .tickPadding(8)
          // Labels come pre-localized from the server (one per axis day), so
          // ticks follow the app's locale instead of D3's default English
          // one and never roll past the selected month's end.
          .tickFormat((day) => axisLabels[day - 1] ?? String(day)),
      )
      .call((g) => g.select(".domain").remove())
      .selectAll("text")
      .attr("class", "text-secondary fill-current")
      .style("font-size", "12px")
      .style("font-weight", "500")
      .attr("text-anchor", (d) =>
        d === 1 ? "start" : d === days ? "end" : "middle",
      );
  }

  _installTooltip(group, x, y, current, comparisons, innerWidth, innerHeight) {
    const tooltip = d3
      .select(this.element)
      .append("div")
      .attr("class", `${CHART_TOOLTIP_CLASSES} opacity-0 top-0`);

    const byDay = (series) => new Map(series.map((d) => [d.day, d]));
    const lines = [
      { label: this.currentLabelValue, color: CURRENT_COLOR, series: current },
      ...comparisons,
    ].map((line) => ({ ...line, pointsByDay: byDay(line.series) }));
    const hoverDays = [
      ...new Set(lines.flatMap((line) => [...line.pointsByDay.keys()])),
    ].sort((a, b) => a - b);

    const bisectDay = d3.bisector((d) => d).center;

    group
      .append("rect")
      .attr("width", innerWidth)
      .attr("height", innerHeight)
      .attr("fill", "none")
      .attr("pointer-events", "all")
      .on("mousemove", (event) => {
        const [xPos] = d3.pointer(event);
        const dayFloat = x.invert(xPos);
        const i = bisectDay(hoverDays, dayFloat);
        const day = hoverDays[Math.max(0, Math.min(i, hoverDays.length - 1))];

        const rows = lines
          .map((line) => ({ ...line, point: line.pointsByDay.get(day) }))
          .filter((row) => row.point);

        const estimatedTooltipWidth = 220;
        const pageWidth = document.body.clientWidth;
        const tooltipX = event.pageX + 10;
        const overflowX = tooltipX + estimatedTooltipWidth - pageWidth;
        const adjustedX =
          overflowX > 0 ? event.pageX - overflowX - 20 : tooltipX;

        group.selectAll(".guideline").remove();
        group.selectAll(".data-point-circle").remove();

        group
          .append("line")
          .attr("class", "guideline text-subdued")
          .attr("x1", x(day))
          .attr("y1", 0)
          .attr("x2", x(day))
          .attr("y2", innerHeight)
          .attr("stroke", "currentColor")
          .attr("stroke-dasharray", "4, 4");

        for (const { point, color } of rows) {
          group
            .append("circle")
            .attr("class", "data-point-circle")
            .attr("cx", x(day))
            .attr("cy", y(point.value))
            .attr("r", 4)
            .attr("fill", color)
            .attr("pointer-events", "none");
        }

        tooltip
          .html(this._tooltipTemplate(rows))
          .style("opacity", 1)
          .style("left", `${adjustedX}px`)
          .style("top", `${event.pageY - 10}px`);
      })
      .on("mouseout", (event) => {
        const hoveringOnGuideline =
          event.toElement?.classList.contains("guideline");

        if (!hoveringOnGuideline) {
          group.selectAll(".guideline").remove();
          group.selectAll(".data-point-circle").remove();
          tooltip.style("opacity", 0);
        }
      });
  }

  _tooltipTemplate(rows) {
    const row = ({ point, color, label }) => `
      <div class="flex items-center gap-1.5 text-primary font-medium tabular-nums">
        <span class="inline-block w-2 h-2 rounded-full" style="background-color: ${color};"></span>
        ${label}: ${this._formatCurrency(point.value)}
      </div>
    `;

    return `
      <div class="text-xs text-secondary mb-1">${rows[0].point.date_formatted}</div>
      <div class="space-y-1">
        ${rows.map(row).join("")}
      </div>
    `;
  }

  _formatCurrency(value) {
    try {
      return new Intl.NumberFormat(undefined, {
        style: "currency",
        currency: this.currencyValue,
      }).format(value);
    } catch {
      return value;
    }
  }

  _formatCompact(value) {
    try {
      return new Intl.NumberFormat(undefined, {
        style: "currency",
        currency: this.currencyValue,
        notation: "compact",
        maximumFractionDigits: 1,
      }).format(value);
    } catch {
      return value;
    }
  }
}
