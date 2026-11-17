import { Controller } from "@hotwired/stimulus";
import * as d3 from "d3";
import {
  CHART_TOOLTIP_CONTEXT_CLASSES,
  CHART_TOOLTIP_VALUE_CLASSES,
  createChartTooltip,
} from "utils/chart_tooltip";

// Connects to data-controller="spending-treemap"
//
// Box size is net spending in the period; fill is the change against the
// category's normal (green = less, red = more, inset surface = about normal),
// as the Reports summary cards colour lower and higher spending.
// Clicking a box opens Transactions filtered to that category and period.
function tint(token, percent) {
  return percent === 100
    ? `var(${token})`
    : `color-mix(in srgb, var(${token}) ${percent}%, var(--color-container))`;
}

export default class extends Controller {
  static targets = ["chart", "legend"];
  static values = {
    tree: { type: Array, default: [] },
    labels: { type: Object, default: {} },
    comparable: { type: Boolean, default: true },
  };

  // Functional tokens mixed into the container colour, so every step follows
  // the theme (light and dark remap --color-success / --color-destructive).
  // The strongest red stops at 80% and the strongest green at 50% (dark
  // mode's green is light), so the theme's text colour keeps AA contrast in
  // both themes. Totals are clamped at zero, so the lowest ratio is -1.
  static STEPS = [
    {
      key: "less",
      min: -1,
      max: -0.5,
      fill: tint("--color-success", 50),
    },
    {
      key: "slightly_less",
      min: -0.5,
      max: -0.15,
      fill: tint("--color-success", 30),
    },
    {
      key: "normal",
      min: -0.15,
      max: 0.15,
      fill: "var(--color-surface-inset)",
    },
    {
      key: "slightly_more",
      min: 0.15,
      max: 0.5,
      fill: tint("--color-destructive", 30),
    },
    {
      key: "more",
      min: 0.5,
      max: 1,
      fill: tint("--color-destructive", 60),
    },
    {
      key: "much_more",
      min: 1,
      max: Number.POSITIVE_INFINITY,
      fill: tint("--color-destructive", 80),
    },
  ];

  #resizeObserver = null;
  #tooltip = null;

  connect() {
    this.#draw();
    this.#drawLegend();
    this.#resizeObserver = new ResizeObserver(() => this.#draw());
    this.#resizeObserver.observe(this.chartTarget);
  }

  disconnect() {
    this.#resizeObserver?.disconnect();
    this.#tooltip?.remove();
  }

  // Without history every box is neutral. A normal of zero with spending is
  // new spending, so it takes the strongest step instead of reading as normal.
  #step(data) {
    const steps = this.constructor.STEPS;
    const normal = steps.find((s) => s.key === "normal");
    if (!this.comparableValue || !data.has_normal) return normal;
    if (data.ratio === null)
      return data.change_sign > 0 ? steps.at(-1) : normal;
    return (
      steps.find((s) => data.ratio >= s.min && data.ratio < s.max) || normal
    );
  }

  #draw() {
    const width = this.chartTarget.clientWidth;
    const height = this.chartTarget.clientHeight;
    if (!width || !height) return;

    d3.select(this.chartTarget).selectAll("*").remove();

    const root = d3
      .hierarchy({ children: this.treeValue })
      .sum((d) => (d.children ? 0 : d.total))
      .sort((a, b) => b.value - a.value);

    d3
      .treemap()
      .size([width, height])
      .paddingOuter(2)
      .paddingTop((d) => (d.depth === 1 ? 20 : 0))
      .paddingInner(2)
      .round(true)(root);

    const svg = d3
      .select(this.chartTarget)
      .append("svg")
      .attr("width", width)
      .attr("height", height)
      .attr("class", "block");

    const groups = svg
      .selectAll("g.group")
      .data(root.children || [])
      .join("g")
      .attr("class", "group");

    // A group with one box would print its label twice.
    groups
      .filter((d) => d.x1 - d.x0 > 48 && d.children.length > 1)
      .append("text")
      .attr("x", (d) => d.x0 + 4)
      .attr("y", (d) => d.y0 + 14)
      .attr("class", "text-primary fill-current text-xs font-medium")
      .text((d) =>
        this.#fit(`${d.data.name} ${d.data.total_label}`, d.x1 - d.x0 - 8, 7),
      );

    const leaves = svg
      .selectAll("g.leaf")
      .data(root.leaves())
      .join("g")
      .attr("class", "leaf cursor-pointer")
      .attr("tabindex", 0)
      .attr("role", "link")
      .attr("aria-label", (d) => d.data.description.join(". "))
      .on("click", (_, d) => this.#open(d))
      .on("keydown", (event, d) => {
        if (event.key === "Enter" || event.key === " ") {
          event.preventDefault();
          // The section's keydown would grab it for reordering
          event.stopPropagation();
          this.#open(d);
        }
      })
      .on("pointermove focus", (event, d) => this.#showTooltip(event, d))
      .on("pointerleave blur", () => this.#hideTooltip());

    leaves
      .append("rect")
      .attr("x", (d) => d.x0)
      .attr("y", (d) => d.y0)
      .attr("width", (d) => Math.max(0, d.x1 - d.x0))
      .attr("height", (d) => Math.max(0, d.y1 - d.y0))
      .attr("rx", 3)
      .attr("fill", (d) => this.#step(d.data).fill)
      .attr("class", "transition-opacity hover:opacity-80");

    const labelled = leaves.filter((d) => d.x1 - d.x0 > 56 && d.y1 - d.y0 > 34);
    labelled
      .append("text")
      .attr("x", (d) => d.x0 + 6)
      .attr("y", (d) => d.y0 + 16)
      .attr(
        "class",
        "text-xs font-medium text-primary fill-current pointer-events-none",
      )
      .text((d) => this.#fit(d.data.name, d.x1 - d.x0 - 12, 6.5));
    labelled
      .append("text")
      .attr("x", (d) => d.x0 + 6)
      .attr("y", (d) => d.y0 + 30)
      .attr("class", "text-xs text-primary fill-current pointer-events-none")
      .text((d) => d.data.total_label);
  }

  #drawLegend() {
    const legend = this.legendTarget;
    legend.replaceChildren();
    if (!this.comparableValue) return;

    for (const step of this.constructor.STEPS) {
      const item = document.createElement("span");
      item.className = "inline-flex items-center gap-1";
      const swatch = document.createElement("span");
      swatch.className = "inline-block w-3 h-3 rounded-sm shadow-border-xs";
      swatch.style.background = step.fill;
      const label = document.createElement("span");
      label.textContent = this.labelsValue.legend?.[step.key] || step.key;
      item.append(swatch, label);
      legend.appendChild(item);
    }
  }

  #showTooltip(event, d) {
    if (!this.#tooltip) {
      this.#tooltip = createChartTooltip(document.body);
      this.#tooltip.style.position = "fixed";
      this.#tooltip.setAttribute("role", "tooltip");
    }
    const [first, ...rest] = d.data.description;
    this.#tooltip.replaceChildren();
    const strong = document.createElement("div");
    strong.className = CHART_TOOLTIP_VALUE_CLASSES;
    strong.textContent = first;
    this.#tooltip.appendChild(strong);
    for (const line of [...rest, this.labelsValue.open]) {
      const row = document.createElement("div");
      row.className = CHART_TOOLTIP_CONTEXT_CLASSES;
      row.textContent = line;
      this.#tooltip.appendChild(row);
    }

    // Shown before measuring, so the edge clamps see its real size.
    this.#tooltip.style.display = "block";
    const rect = event.currentTarget.getBoundingClientRect();
    const x = event.clientX ?? rect.right;
    const y = event.clientY ?? rect.top;
    this.#tooltip.style.left = `${Math.min(x + 12, window.innerWidth - this.#tooltip.offsetWidth - 8)}px`;
    this.#tooltip.style.top = `${Math.max(8, y - this.#tooltip.offsetHeight - 12)}px`;
  }

  #hideTooltip() {
    if (this.#tooltip) this.#tooltip.style.display = "none";
  }

  #open(d) {
    if (d.data.href) window.Turbo.visit(d.data.href);
  }

  // Truncate to roughly fit `width` pixels at `charWidth` px per character.
  #fit(text, width, charWidth) {
    const max = Math.floor(width / charWidth);
    if (max < 2) return "";
    return text.length > max ? `${text.slice(0, max - 1)}…` : text;
  }
}
