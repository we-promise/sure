import { Controller } from "@hotwired/stimulus";
import * as d3 from "d3";

// Connects to data-controller="spending-treemap"
//
// Box size is net spending in the period; fill is the change against the
// category's normal (blue = less, red = more, inset surface = about normal).
// Clicking a box opens Transactions filtered to that category and period.
export default class extends Controller {
  static targets = ["chart", "legend"];
  static values = {
    tree: { type: Array, default: [] },
    labels: { type: Object, default: {} },
    comparable: { type: Boolean, default: true },
  };

  static STEPS = [
    {
      key: "much_less",
      min: Number.NEGATIVE_INFINITY,
      max: -1,
      fill: "var(--color-blue-600)",
      ink: "var(--color-white)",
    },
    {
      key: "less",
      min: -1,
      max: -0.5,
      fill: "var(--color-blue-400)",
      ink: "var(--color-black)",
    },
    {
      key: "slightly_less",
      min: -0.5,
      max: -0.15,
      fill: "var(--color-blue-200)",
      ink: "var(--color-black)",
    },
    {
      key: "normal",
      min: -0.15,
      max: 0.15,
      fill: "var(--color-surface-inset)",
      ink: null,
    },
    {
      key: "slightly_more",
      min: 0.15,
      max: 0.5,
      fill: "var(--color-red-200)",
      ink: "var(--color-black)",
    },
    {
      key: "more",
      min: 0.5,
      max: 1,
      fill: "var(--color-red-400)",
      ink: "var(--color-black)",
    },
    {
      key: "much_more",
      min: 1,
      max: Number.POSITIVE_INFINITY,
      fill: "var(--color-red-600)",
      ink: "var(--color-white)",
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

  #step(ratio) {
    if (ratio === null || ratio === undefined) return this.constructor.STEPS[3];
    return (
      this.constructor.STEPS.find((s) => ratio >= s.min && ratio < s.max) ||
      this.constructor.STEPS[3]
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

    groups
      .filter((d) => d.x1 - d.x0 > 48)
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
      .attr("aria-label", (d) => this.#describe(d).join(". "))
      .on("click", (_, d) => this.#open(d))
      .on("keydown", (event, d) => {
        if (event.key === "Enter" || event.key === " ") {
          event.preventDefault();
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
      .attr(
        "fill",
        (d) => this.#step(this.comparableValue ? d.data.ratio : null).fill,
      )
      .attr("class", "transition-opacity hover:opacity-80");

    const labelled = leaves.filter((d) => d.x1 - d.x0 > 56 && d.y1 - d.y0 > 34);
    const ink = (d) =>
      this.#step(this.comparableValue ? d.data.ratio : null).ink;
    labelled
      .append("text")
      .attr("x", (d) => d.x0 + 6)
      .attr("y", (d) => d.y0 + 16)
      .attr(
        "class",
        (d) =>
          `text-xs font-medium pointer-events-none ${ink(d) ? "" : "text-primary fill-current"}`,
      )
      .style("fill", (d) => ink(d))
      .text((d) => this.#fit(d.data.name, d.x1 - d.x0 - 12, 6.5));
    labelled
      .append("text")
      .attr("x", (d) => d.x0 + 6)
      .attr("y", (d) => d.y0 + 30)
      .attr(
        "class",
        (d) =>
          `text-xs pointer-events-none ${ink(d) ? "" : "text-primary fill-current"}`,
      )
      .style("fill", (d) => ink(d))
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

  #describe(d) {
    const parent = d.parent?.data?.name;
    const name =
      parent && parent !== d.data.name
        ? `${parent} › ${d.data.name}`
        : d.data.name;
    const lines = [`${name}: ${d.data.total_full}`];
    if (!this.comparableValue || d.data.normal_label === null) {
      lines.push(this.labelsValue.no_normal);
    } else {
      lines.push(`${this.labelsValue.normal} ${d.data.normal_label}`);
      if (d.data.change_label) {
        const pct =
          d.data.ratio === null
            ? ""
            : ` (${Math.round(Math.abs(d.data.ratio) * 100)}%)`;
        lines.push(
          `${d.data.change_sign < 0 ? this.labelsValue.less : this.labelsValue.more} ${d.data.change_label}${pct}`,
        );
      }
    }
    return lines;
  }

  #showTooltip(event, d) {
    if (!this.#tooltip) {
      this.#tooltip = document.createElement("div");
      this.#tooltip.className =
        "fixed z-50 pointer-events-none bg-container text-primary shadow-border-xs rounded-lg px-3 py-2 text-xs max-w-64";
      this.#tooltip.setAttribute("role", "tooltip");
      document.body.appendChild(this.#tooltip);
    }
    const [first, ...rest] = this.#describe(d);
    this.#tooltip.replaceChildren();
    const strong = document.createElement("div");
    strong.className = "font-medium text-sm";
    strong.textContent = first;
    this.#tooltip.appendChild(strong);
    for (const line of [...rest, this.labelsValue.open]) {
      const row = document.createElement("div");
      row.className = "text-secondary";
      row.textContent = line;
      this.#tooltip.appendChild(row);
    }

    const rect = event.currentTarget.getBoundingClientRect();
    const x = event.clientX ?? rect.right;
    const y = event.clientY ?? rect.top;
    this.#tooltip.style.left = `${Math.min(x + 12, window.innerWidth - this.#tooltip.offsetWidth - 8)}px`;
    this.#tooltip.style.top = `${Math.max(8, y - this.#tooltip.offsetHeight - 12)}px`;
    this.#tooltip.hidden = false;
  }

  #hideTooltip() {
    if (this.#tooltip) this.#tooltip.hidden = true;
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
