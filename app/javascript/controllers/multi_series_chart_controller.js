import { Controller } from "@hotwired/stimulus";
import * as d3 from "d3";
import {
  CHART_TOOLTIP_CLASSES,
  CHART_TOOLTIP_CONTEXT_CLASSES,
  CHART_TOOLTIP_VALUE_CLASSES,
} from "utils/chart_tooltip";

// One line per selected category for the Reports activity breakdown. The
// dashboard charts are single-series or fixed two-series, so this controller
// keeps the same lifecycle (ResizeObserver, turbo:load reinstall, page-relative
// tooltip) but takes an arbitrary number of category series.
export default class extends Controller {
  static values = {
    data: Object,
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
    const series = this.dataValue?.series || [];
    const points = series[0]?.values?.length || 0;
    const granularity = this.dataValue?.granularity || "month";

    if (width < 50 || height < 50 || series.length === 0 || points < 1) return;

    // A month axis that crosses a year boundary needs a year row; otherwise
    // "Jan" repeats with no clue which year it belongs to.
    const years = new Set(
      (series[0]?.values || []).map((v) => v.date.slice(0, 4)),
    );
    const showYearRow = granularity === "month" && years.size > 1;

    const margin = {
      top: 12,
      right: 12,
      bottom: showYearRow ? 44 : 28,
      left: 56,
    };
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
      .scalePoint()
      .domain(d3.range(points))
      .range([0, innerWidth])
      .padding(0.15);

    // One bucket (for example Year on a one-year period) has no line to draw.
    // Centre its dot and label so the total is still visible.
    const xAt = (index) => (points === 1 ? innerWidth / 2 : x(index));

    const maxValue =
      d3.max(series, (s) => d3.max(s.values, (v) => Number(v.value) || 0)) || 0;
    const y = d3
      .scaleLinear()
      .domain([0, maxValue > 0 ? maxValue * 1.1 : 1])
      .nice()
      .range([innerHeight, 0]);

    this._drawGrid(group, y, innerWidth);

    const line = d3
      .line()
      .x((_value, index) => xAt(index))
      .y((value) => y(Number(value.value) || 0));

    series.forEach((category) => {
      if (points > 1) {
        group
          .append("path")
          .datum(category.values)
          .attr("fill", "none")
          .attr("stroke", category.color || "var(--color-gray-400)")
          .attr("stroke-width", 2)
          .attr("stroke-linejoin", "round")
          .attr("stroke-linecap", "round")
          .attr("d", line);
      }

      // Dense series read better without a dot on every point. Hover still
      // shows the focus dot and the exact value.
      if (points <= 12) {
        group
          .append("g")
          .selectAll("circle")
          .data(category.values)
          .join("circle")
          .attr("cx", (_value, index) => xAt(index))
          .attr("cy", (value) => y(Number(value.value) || 0))
          .attr("r", points === 1 ? 4 : 2.5)
          .attr("fill", category.color || "var(--color-gray-400)");
      }
    });

    this._drawXAxisLabels(
      group,
      xAt,
      series[0].values,
      innerWidth,
      innerHeight,
      showYearRow,
    );

    const guideline = group
      .append("line")
      .attr("y1", 0)
      .attr("y2", innerHeight)
      .attr("stroke", "currentColor")
      .attr("stroke-dasharray", "4, 4")
      .attr("class", "text-subdued")
      .style("display", "none");

    const focus = group.append("g").style("display", "none");
    const focusDots = series.map((category) =>
      focus
        .append("circle")
        .attr("r", 4)
        .attr("fill", category.color || "var(--color-gray-400)")
        .attr("stroke", "var(--color-container)")
        .attr("stroke-width", 1.5),
    );

    const tooltip = d3
      .select(this.element)
      .append("div")
      .attr("class", `${CHART_TOOLTIP_CLASSES} opacity-0 top-0`);

    const hide = () => {
      tooltip.style("opacity", 0);
      guideline.style("display", "none");
      focus.style("display", "none");
    };

    const overlay = group
      .append("rect")
      .attr("width", innerWidth)
      .attr("height", innerHeight)
      .attr("fill", "none")
      .attr("pointer-events", "all");

    overlay
      .on("mousemove", (event) => {
        const [pointerX] = d3.pointer(event);
        const index = this._nearestIndex(xAt, pointerX, points);
        const datum = series[0].values[index];

        guideline
          .attr("x1", xAt(index))
          .attr("x2", xAt(index))
          .style("display", null);
        focus.style("display", null);
        focusDots.forEach((dot, seriesIndex) => {
          dot
            .attr("cx", xAt(index))
            .attr(
              "cy",
              y(Number(series[seriesIndex].values[index]?.value) || 0),
            );
        });

        tooltip
          .html(this._tooltipTemplate(index, series, datum))
          .style("opacity", 1)
          .style("left", `${this._tooltipX(event.pageX)}px`)
          .style("top", `${event.pageY - 10}px`);
      })
      .on("mouseleave", hide);
  }

  _drawGrid(group, y, innerWidth) {
    const ticks = y.ticks(4);

    group
      .append("g")
      .selectAll("line")
      .data(ticks)
      .join("line")
      .attr("x1", 0)
      .attr("x2", innerWidth)
      .attr("y1", (tick) => y(tick))
      .attr("y2", (tick) => y(tick))
      .attr("stroke", "var(--color-gray-300)")
      .attr("stroke-opacity", 0.5);

    group
      .append("g")
      .selectAll("text")
      .data(ticks)
      .join("text")
      .attr("x", -8)
      .attr("y", (tick) => y(tick))
      .attr("dy", "0.32em")
      .attr("text-anchor", "end")
      .attr("class", "text-secondary fill-current")
      .style("font-size", "11px")
      .text((tick) => this._formatCompact(tick));
  }

  _drawXAxisLabels(group, xAt, values, innerWidth, innerHeight, showYearRow) {
    const points = values.length;
    const maxLabels = Math.max(2, Math.floor(innerWidth / 64));
    const step = Math.max(1, Math.ceil(points / maxLabels));
    const labelled = new Set();

    // Keep January visible even when the step skips it: it marks the start of
    // the year that the row below names.
    values.forEach((value, index) => {
      const isYearStart = value.date.slice(5) === "01-01";
      if (
        index === 0 ||
        index === points - 1 ||
        index % step === 0 ||
        (showYearRow && isYearStart)
      ) {
        labelled.add(index);
      }
    });

    group
      .append("g")
      .selectAll("text")
      .data(values)
      .join("text")
      .attr("x", (_value, index) => xAt(index))
      .attr("y", innerHeight + 16)
      .attr("text-anchor", "middle")
      .attr("class", "text-secondary fill-current")
      .style("font-size", "11px")
      .style("display", (_value, index) =>
        labelled.has(index) ? null : "none",
      )
      .text((value) => value.short_label || value.label);

    if (!showYearRow) return;

    const runs = [];
    values.forEach((value, index) => {
      const year = value.date.slice(0, 4);
      const current = runs[runs.length - 1];

      if (current && current.year === year) {
        current.end = index;
      } else {
        runs.push({ year, start: index, end: index });
      }
    });

    // A faint rule at each new year, through the plot, so the eye can separate
    // the two periods even where the month labels are sparse.
    runs.slice(1).forEach((run) => {
      group
        .append("line")
        .attr("x1", xAt(run.start))
        .attr("x2", xAt(run.start))
        .attr("y1", 0)
        .attr("y2", innerHeight + 22)
        .attr("stroke", "var(--color-gray-300)")
        .attr("stroke-opacity", 0.7)
        .attr("stroke-dasharray", "3, 3");
    });

    group
      .append("g")
      .selectAll("text")
      .data(runs)
      .join("text")
      .attr("x", (run) => (xAt(run.start) + xAt(run.end)) / 2)
      .attr("y", innerHeight + 34)
      .attr("text-anchor", "middle")
      .attr("class", "text-primary fill-current")
      .style("font-size", "10px")
      .style("font-weight", "600")
      .style("letter-spacing", "0.02em")
      .text((run) => run.year);
  }

  _nearestIndex(xAt, pointerX, points) {
    let nearest = 0;

    for (let index = 1; index < points; index += 1) {
      if (Math.abs(xAt(index) - pointerX) < Math.abs(xAt(nearest) - pointerX)) {
        nearest = index;
      }
    }

    return nearest;
  }

  _tooltipX(pageX) {
    const estimatedTooltipWidth = 240;
    const tooltipX = pageX + 10;
    const overflowX =
      tooltipX + estimatedTooltipWidth - document.body.clientWidth;

    return overflowX > 0 ? pageX - overflowX - 20 : tooltipX;
  }

  _tooltipTemplate(index, series, datum) {
    const rows = series
      .map((category) => {
        const value = Number(category.values[index]?.value) || 0;
        return `
          <div class="flex items-center justify-between gap-4 ${CHART_TOOLTIP_VALUE_CLASSES}">
            <span class="flex items-center gap-1.5 text-secondary">
              <span class="inline-block h-2 w-2 rounded-full" style="background-color: ${category.color || "var(--color-gray-400)"};"></span>
              ${this._escape(category.name)}
            </span>
            <span class="text-primary">${this._formatCurrency(value)}</span>
          </div>
        `;
      })
      .join("");

    return `<div class="${CHART_TOOLTIP_CONTEXT_CLASSES}">${this._escape(datum.label)}</div>${rows}`;
  }

  _formatCurrency(value) {
    try {
      return new Intl.NumberFormat(undefined, {
        style: "currency",
        currency: this.currencyValue,
        maximumFractionDigits: 2,
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

  _escape(value) {
    return String(value ?? "").replace(
      /[&<>"']/g,
      (character) =>
        ({
          "&": "&amp;",
          "<": "&lt;",
          ">": "&gt;",
          '"': "&quot;",
          "'": "&#39;",
        })[character],
    );
  }
}
