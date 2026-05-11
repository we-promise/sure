import { Controller } from "@hotwired/stimulus";
import * as d3 from "d3";

// Projection chart for a savings goal. Renders:
//   - Saved area + line from goal creation → today (solid)
//   - Dashed projection line from today → target date (yellow if behind,
//     green if on track)
//   - Horizontal dashed target line with label
//   - Today marker (vertical line + dot)
//
// Data shape passed via `data-savings-goal-projection-chart-data-value`
// matches SavingsGoal#projection_payload.
export default class extends Controller {
  static values = { data: Object };

  connect() {
    this._draw();
    this._resize = this._draw.bind(this);
    window.addEventListener("resize", this._resize);
  }

  disconnect() {
    window.removeEventListener("resize", this._resize);
  }

  _draw() {
    const root = this.element;
    root.innerHTML = "";

    const data = this.dataValue || {};
    const width = root.clientWidth || 720;
    const height = root.clientHeight || 240;
    if (width <= 0 || height <= 0) return;

    const isDark = document.documentElement.getAttribute("data-theme") === "dark";
    const textPrimary = isDark ? "#ffffff" : "#171717";
    const textSecondary = isDark ? "#cfcfcf" : "#737373";
    const borderSubdued = isDark ? "rgba(255,255,255,0.15)" : "rgba(0,0,0,0.10)";
    const containerBg = isDark ? "#0a0a0a" : "#ffffff";

    const margin = { top: 28, right: 24, bottom: 28, left: 16 };
    const innerWidth = width - margin.left - margin.right;
    const innerHeight = height - margin.top - margin.bottom;

    const start = new Date(data.start_date);
    const today = new Date(data.today);
    const target = data.target_date ? new Date(data.target_date) : null;
    const targetAmount = data.target_amount || 0;
    const currentAmount = data.current_amount || 0;
    const avgMonthly = data.avg_monthly || 0;

    const endDate = target || new Date(today.getTime() + 30 * 24 * 60 * 60 * 1000);

    const rawSavedSeries = (data.saved_series || []).map((p) => ({ date: new Date(p.date), value: p.value }));
    const firstContribDate = rawSavedSeries[0]?.date;
    const savedSeries = [];
    // Only seed a (start, 0) point when start_date predates the first
    // contribution. Otherwise the line draws a vertical jump up at the
    // chart's left edge.
    if (!firstContribDate || firstContribDate.getTime() > start.getTime()) {
      savedSeries.push({ date: start, value: 0 });
    }
    savedSeries.push(...rawSavedSeries);
    if (savedSeries.length && savedSeries[savedSeries.length - 1].date < today) {
      savedSeries.push({ date: today, value: currentAmount });
    }

    const projectionEnd = target
      ? Math.max(currentAmount, currentAmount + avgMonthly * Math.max(0, this._monthsBetween(today, target)))
      : currentAmount;
    const projectionSeries = target
      ? [
          { date: today, value: currentAmount },
          { date: target, value: projectionEnd },
        ]
      : [];

    const yMax = Math.max(targetAmount * 1.05, projectionEnd, currentAmount, 1);

    const x = d3.scaleTime().domain([start, endDate]).range([margin.left, margin.left + innerWidth]);
    const y = d3.scaleLinear().domain([0, yMax]).range([margin.top + innerHeight, margin.top]);

    const svg = d3
      .select(root)
      .append("svg")
      .attr("width", width)
      .attr("height", height)
      .attr("viewBox", `0 0 ${width} ${height}`)
      .attr("preserveAspectRatio", "none");

    const defs = svg.append("defs");
    const gradient = defs
      .append("linearGradient")
      .attr("id", `saved-fill-${this._id()}`)
      .attr("x1", 0).attr("y1", 0).attr("x2", 0).attr("y2", 1);
    gradient.append("stop").attr("offset", "0%").attr("stop-color", textPrimary).attr("stop-opacity", 0.22);
    gradient.append("stop").attr("offset", "100%").attr("stop-color", textPrimary).attr("stop-opacity", 0);

    if (targetAmount > 0) {
      svg
        .append("line")
        .attr("x1", margin.left)
        .attr("x2", margin.left + innerWidth)
        .attr("y1", y(targetAmount))
        .attr("y2", y(targetAmount))
        .attr("stroke", borderSubdued)
        .attr("stroke-width", 1)
        .attr("stroke-dasharray", "3 3");

      svg
        .append("text")
        .attr("x", margin.left + innerWidth - 4)
        .attr("y", y(targetAmount) - 6)
        .attr("text-anchor", "end")
        .attr("font-size", 10)
        .attr("fill", textPrimary)
        .text(`Target · ${this._fmtMoney(targetAmount, data.currency)}`);
    }

    const area = d3
      .area()
      .x((d) => x(d.date))
      .y0(margin.top + innerHeight)
      .y1((d) => y(d.value))
      .curve(d3.curveMonotoneX);

    const line = d3
      .line()
      .x((d) => x(d.date))
      .y((d) => y(d.value))
      .curve(d3.curveMonotoneX);

    svg
      .append("path")
      .datum(savedSeries)
      .attr("fill", `url(#saved-fill-${this._id()})`)
      .attr("d", area);

    svg
      .append("path")
      .datum(savedSeries)
      .attr("fill", "none")
      .attr("stroke", textPrimary)
      .attr("stroke-width", 2)
      .attr("stroke-linejoin", "round")
      .attr("stroke-linecap", "round")
      .attr("d", line);

    if (projectionSeries.length) {
      const willHit = projectionEnd >= targetAmount;
      svg
        .append("path")
        .datum(projectionSeries)
        .attr("fill", "none")
        .attr("stroke", willHit ? "var(--color-green-600)" : "var(--color-yellow-600)")
        .attr("stroke-width", 2)
        .attr("stroke-linecap", "round")
        .attr("stroke-dasharray", "4 4")
        .attr("d", line);
    }

    svg
      .append("line")
      .attr("x1", x(today))
      .attr("x2", x(today))
      .attr("y1", margin.top)
      .attr("y2", margin.top + innerHeight)
      .attr("stroke", borderSubdued)
      .attr("stroke-width", 1)
      .attr("stroke-dasharray", "2 4");

    svg
      .append("circle")
      .attr("cx", x(today))
      .attr("cy", y(currentAmount))
      .attr("r", 4)
      .attr("fill", textPrimary)
      .attr("stroke", containerBg)
      .attr("stroke-width", 2);

    const tickFmt = d3.timeFormat("%b %y");
    const tickCount = Math.min(5, Math.max(2, Math.round(innerWidth / 110)));
    const ticks = x.ticks(tickCount);
    svg
      .append("g")
      .selectAll("text")
      .data(ticks)
      .enter()
      .append("text")
      .attr("x", (d) => x(d))
      .attr("y", height - 8)
      .attr("text-anchor", "middle")
      .attr("font-size", 10)
      .attr("fill", textSecondary)
      .text((d) => tickFmt(d));
  }

  _monthsBetween(a, b) {
    return (b - a) / (1000 * 60 * 60 * 24 * 30.44);
  }

  _fmtMoney(amount, currency) {
    const symbol = currency === "EUR" ? "€" : currency === "GBP" ? "£" : "$";
    return `${symbol}${Math.round(amount).toLocaleString()}`;
  }

  _id() {
    if (!this._cachedId) {
      this._cachedId = Math.random().toString(36).slice(2, 8);
    }
    return this._cachedId;
  }
}
