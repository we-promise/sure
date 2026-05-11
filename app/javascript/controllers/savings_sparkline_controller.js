import { Controller } from "@hotwired/stimulus";
import * as d3 from "d3";

// Sparkline area chart for the savings hero card. Tiny, axis-less,
// labelless — just the green line + soft area fill + end dot.
// Data: [{ date: "YYYY-MM-DD", value: Number }, ...]
export default class extends Controller {
  static values = { series: Array };

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

    const series = (this.seriesValue || []).map((p) => ({
      date: new Date(p.date),
      value: Number(p.value || 0),
    }));
    if (series.length < 2) return;

    const width = root.clientWidth || 600;
    const height = root.clientHeight || 140;
    if (width <= 0 || height <= 0) return;

    const margin = { top: 8, right: 12, bottom: 4, left: 8 };
    const innerWidth = width - margin.left - margin.right;
    const innerHeight = height - margin.top - margin.bottom;

    const x = d3
      .scaleTime()
      .domain(d3.extent(series, (d) => d.date))
      .range([margin.left, margin.left + innerWidth]);

    const yMin = Math.min(...series.map((d) => d.value));
    const yMax = Math.max(...series.map((d) => d.value));
    // Don't clamp to 0 — savings totals can be negative under certain
    // demo / edge conditions, and clamping pushes the line off-canvas.
    const range = yMax - yMin;
    const padding = range > 0 ? range * 0.15 : Math.abs(yMax) * 0.05 || 1;
    const y = d3
      .scaleLinear()
      .domain([yMin - padding, yMax + padding])
      .range([margin.top + innerHeight, margin.top]);

    const svg = d3
      .select(root)
      .append("svg")
      .attr("width", width)
      .attr("height", height)
      .attr("viewBox", `0 0 ${width} ${height}`)
      .attr("preserveAspectRatio", "none");

    const gradId = `sparkline-fill-${Math.random().toString(36).slice(2, 8)}`;
    const defs = svg.append("defs");
    const grad = defs
      .append("linearGradient")
      .attr("id", gradId)
      .attr("x1", 0).attr("y1", 0).attr("x2", 0).attr("y2", 1);
    grad.append("stop").attr("offset", "0%").attr("stop-color", "var(--color-green-500)").attr("stop-opacity", 0.18);
    grad.append("stop").attr("offset", "100%").attr("stop-color", "var(--color-green-500)").attr("stop-opacity", 0);

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
      .datum(series)
      .attr("fill", `url(#${gradId})`)
      .attr("d", area);

    svg
      .append("path")
      .datum(series)
      .attr("fill", "none")
      .attr("stroke", "var(--color-green-600)")
      .attr("stroke-width", 2)
      .attr("stroke-linejoin", "round")
      .attr("stroke-linecap", "round")
      .attr("d", line);

    const last = series[series.length - 1];
    svg
      .append("circle")
      .attr("cx", x(last.date))
      .attr("cy", y(last.value))
      .attr("r", 4)
      .attr("fill", "var(--color-green-600)")
      .attr("stroke", "var(--bg-container)")
      .attr("stroke-width", 2);
  }
}
