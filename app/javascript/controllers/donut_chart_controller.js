import { Controller } from "@hotwired/stimulus";
import * as d3 from "d3";
import { buildCategoryTransactionsUrl } from "utils/transactions_filter_url";

// Connects to data-controller="donut-chart"
export default class extends Controller {
  static targets = ["chartContainer", "contentContainer", "defaultContent", "amount"];
  static values = {
    segments: { type: Array, default: [] },
    unusedSegmentId: { type: String, default: "unused" },
    overageSegmentId: { type: String, default: "overage" },
    segmentHeight: { type: Number, default: 3 },
    segmentOpacity: { type: Number, default: 1 },
    extendedHover: { type: Boolean, default: false },
    hoverExtension: { type: Number, default: 3 },
    enableClick: { type: Boolean, default: false },
    startDate: String,
    endDate: String,
  };

  #viewBoxSize = 100;
  #minSegmentAngle = 0.02; // Minimum angle in radians (~1.15 degrees)
  #padAngle = 0.005; // Spacing between segments (~0.29 degrees)
  #visiblePaths = null;
  #resizeObserver = null;
  #measureCanvas = null;
  // Largest square inscribed in a circle has side D/√2 ≈ 0.707·D. A single
  // line of text only needs horizontal room, so 0.78 leaves a touch of
  // padding without being overly conservative.
  #innerRingTextWidthRatio = 0.78;
  // ~text-sm (0.875rem at the default 16px root). Acceptance criterion is
  // "shrink proportionally, never below text-sm".
  #minAmountFontSizePx = 14;

  connect() {
    this.#draw();
    this.#fitAmountTargets();
    document.addEventListener("turbo:load", this.#redraw);
    this.element.addEventListener("mouseleave", this.#clearSegmentHover);
    this.contentContainerTarget.addEventListener("mouseleave", this.#clearSegmentHover);

    if (typeof ResizeObserver !== "undefined" && this.hasChartContainerTarget) {
      this.#resizeObserver = new ResizeObserver(() => this.#fitAmountTargets());
      this.#resizeObserver.observe(this.chartContainerTarget);
    }
  }

  disconnect() {
    this.#teardown();
    document.removeEventListener("turbo:load", this.#redraw);
    this.element.removeEventListener("mouseleave", this.#clearSegmentHover);
    this.contentContainerTarget.removeEventListener("mouseleave", this.#clearSegmentHover);

    if (this.#resizeObserver) {
      this.#resizeObserver.disconnect();
      this.#resizeObserver = null;
    }
  }

  get #data() {
    const totalPieValue = this.segmentsValue.reduce(
      (acc, s) => acc + Number(s.amount),
      0,
    );

    // Overage is always first segment, unused is always last segment
    return this.segmentsValue
      .filter((s) => s.amount > 0)
      .map((s) => ({
        ...s,
        amount: Math.max(
          Number(s.amount),
          totalPieValue * (this.#minSegmentAngle / (2 * Math.PI)),
        ),
      }))
      .sort((a, b) => {
        if (a.id === this.overageSegmentIdValue) return -1;
        if (b.id === this.overageSegmentIdValue) return 1;
        if (a.id === this.unusedSegmentIdValue) return 1;
        if (b.id === this.unusedSegmentIdValue) return -1;
        return b.amount - a.amount;
      });
  }

  #redraw = () => {
    this.#teardown();
    this.#draw();
  };

  #teardown() {
    if (this.hasChartContainerTarget) {
      d3.select(this.chartContainerTarget).selectAll("*").remove();
    }
    this.#visiblePaths = null;
  }

  #draw() {
    if (!this.hasChartContainerTarget) return;

    const svg = d3
      .select(this.chartContainerTarget)
      .append("svg")
      .attr("viewBox", `0 0 ${this.#viewBoxSize} ${this.#viewBoxSize}`) // Square aspect ratio
      .attr("preserveAspectRatio", "xMidYMid meet")
      .attr("class", "w-full h-full");

    const pie = d3
      .pie()
      .sortValues(null) // Preserve order of segments
      .value((d) => d.amount);

    const mainArc = d3
      .arc()
      .innerRadius(this.#viewBoxSize / 2 - this.segmentHeightValue)
      .outerRadius(this.#viewBoxSize / 2)
      .cornerRadius(this.segmentHeightValue)
      .padAngle(this.#padAngle);

    const g = svg
      .append("g")
      .attr(
        "transform",
        `translate(${this.#viewBoxSize / 2}, ${this.#viewBoxSize / 2})`,
      );

    const segmentGroups = g
      .selectAll("arc")
      .data(pie(this.#data))
      .enter()
      .append("g")
      .attr("class", "arc pointer-events-auto");

    // Add invisible hover paths with extended area if enabled
    if (this.extendedHoverValue) {
      const hoverArc = d3
        .arc()
        .innerRadius(this.#viewBoxSize / 2 - this.segmentHeightValue - this.hoverExtensionValue)
        .outerRadius(this.#viewBoxSize / 2 + this.hoverExtensionValue)
        .padAngle(this.#padAngle);

      segmentGroups
        .append("path")
        .attr("class", "hover-path")
        .attr("d", hoverArc)
        .attr("fill", "transparent")
        .attr("data-segment-id", (d) => d.data.id)
        .style("pointer-events", "all");
    }

    // Add visible paths
    const segmentArcs = segmentGroups
      .append("path")
      .attr("class", "visible-path")
      .attr("data-segment-id", (d) => d.data.id)
      .attr("data-original-color", this.#transformRingColor)
      .attr("fill", this.#transformRingColor)
      .attr("d", mainArc);

    // Disable pointer events on visible paths if extended hover is enabled
    if (this.extendedHoverValue) {
      segmentArcs.style("pointer-events", "none");
    }

    // Cache the visible paths selection for performance
    this.#visiblePaths = d3.select(this.chartContainerTarget).selectAll("path.visible-path");

    // Ensures that user can click on default content without triggering hover on a segment if that is their intent
    let hoverTimeout = null;

    segmentGroups
      .on("mouseover", (event) => {
        hoverTimeout = setTimeout(() => {
          this.#clearSegmentHover();
          this.#handleSegmentHover(event);
        }, 10);
      })
      .on("mouseleave", (event, d) => {
        clearTimeout(hoverTimeout);
        const leavingUnused = d.data.id === this.unusedSegmentIdValue;
        if (leavingUnused || !this.contentContainerTarget.contains(event.relatedTarget)) {
          this.#clearSegmentHover();
        }
      })
      .on("click", (event, d) => {
        if (this.enableClickValue) {
          this.#handleClick(d.data);
        }
      });
  }

  #transformRingColor = ({ data: { id, color } }) => {
    if (id === this.unusedSegmentIdValue || id === this.overageSegmentIdValue) {
      return color;
    }

    const reducedOpacityColor = d3.color(color);
    reducedOpacityColor.opacity = this.segmentOpacityValue;
    return reducedOpacityColor;
  };

  // Highlights segment and shows segment specific content (all other segments are grayed out)
  #handleSegmentHover(event) {
    const segmentId = event.target.dataset.segmentId;
    const template = this.element.querySelector(`#segment_${segmentId}`);
    const unusedSegmentId = this.unusedSegmentIdValue;

    if (!template) return;

    // Use cached selection if available for better performance
    const paths = this.#visiblePaths || d3.select(this.chartContainerTarget).selectAll("path.visible-path");

    paths.attr("fill", function () {
      if (this.dataset.segmentId === segmentId) {
        if (this.dataset.segmentId === unusedSegmentId) {
          return "var(--budget-unused-fill)";
        }

        return this.dataset.originalColor;
      }

      return "var(--budget-unallocated-fill)";
    });

    this.defaultContentTarget.classList.add("hidden");
    template.classList.remove("hidden");

    // The newly-visible amount is now in flow; re-fit in case the container
    // size has changed since initial draw.
    this.#fitAmountTargets(template);
  }

  // Restores original segment colors and hides segment specific content
  #clearSegmentHover = () => {
    this.defaultContentTarget.classList.remove("hidden");

    // Use cached selection if available for better performance
    const paths = this.#visiblePaths || d3.select(this.chartContainerTarget).selectAll("path.visible-path");

    paths
      .attr("fill", function () {
        return this.dataset.originalColor;
      })
      .style("opacity", null); // Clear inline opacity style

    for (const child of this.contentContainerTarget.children) {
      if (child !== this.defaultContentTarget) {
        child.classList.add("hidden");
      }
    }
  };

  // Handles click on segment (optional, controlled by enableClick value)
  #handleClick(segment) {
    if (!segment.name) return;

    Turbo.visit(
      buildCategoryTransactionsUrl({
        name: segment.name,
        startDate: this.startDateValue,
        endDate: this.endDateValue,
      }),
    );
  }

  // Public methods for external highlighting (e.g., from category list hover)
  highlightSegment(event) {
    const segmentId = event.currentTarget.dataset.categoryId;

    // Use cached selection if available for better performance
    const paths = this.#visiblePaths || d3.select(this.chartContainerTarget).selectAll("path.visible-path");

    paths.style("opacity", function() {
      return this.dataset.segmentId === segmentId ? 1 : 0.3;
    });
  }

  unhighlightSegment() {
    // Use cached selection if available for better performance
    const paths = this.#visiblePaths || d3.select(this.chartContainerTarget).selectAll("path.visible-path");

    paths.style("opacity", null); // Clear inline opacity style
  }

  // Shrinks amount text down so it never overflows the inner ring of the
  // donut. Re-runs on draw, on resize, and when a segment template becomes
  // visible. Optional `scope` limits the work to a subtree (e.g. the segment
  // that just appeared).
  #fitAmountTargets(scope = null) {
    if (!this.hasChartContainerTarget || !this.hasAmountTarget) return;

    // The donut SVG uses `preserveAspectRatio="xMidYMid meet"`, so the actual
    // rendered diameter is the *smaller* of the container's width and height.
    // Using width alone over-estimates available room in non-square cells
    // (e.g. the budget show page renders the donut inside a grid column that
    // grows wider than tall on large viewports).
    const rect = this.chartContainerTarget.getBoundingClientRect();
    const containerSize = Math.min(rect.width, rect.height);
    if (containerSize <= 0) return;

    const innerDiameterRatio =
      (this.#viewBoxSize - 2 * this.segmentHeightValue) / this.#viewBoxSize;
    const availableWidth = containerSize * innerDiameterRatio * this.#innerRingTextWidthRatio;
    if (availableWidth <= 0) return;

    const targets = scope
      ? this.amountTargets.filter((el) => scope.contains(el))
      : this.amountTargets;

    targets.forEach((el) => this.#fitAmountElement(el, availableWidth));
  }

  #fitAmountElement(element, availableWidth) {
    // Reset previous inline sizing so we measure at the source size each pass.
    element.style.fontSize = "";

    const text = element.textContent.trim();
    if (!text) return;

    const computed = window.getComputedStyle(element);
    const baseFontSize = Number.parseFloat(computed.fontSize);
    if (!baseFontSize) return;

    // Canvas-based measurement works for hidden elements (segment_<id>
    // templates start with `display: none`), where scrollWidth would be 0.
    const intrinsicWidth = this.#measureTextWidth(text, computed, baseFontSize);
    if (intrinsicWidth <= 0 || intrinsicWidth <= availableWidth) return;

    const scaled = Math.max(
      this.#minAmountFontSizePx,
      Math.floor((availableWidth / intrinsicWidth) * baseFontSize),
    );

    if (Math.abs(scaled - baseFontSize) >= 1) {
      element.style.fontSize = `${scaled}px`;
    }
  }

  #measureTextWidth(text, computed, fontSize) {
    if (!this.#measureCanvas) {
      this.#measureCanvas = document.createElement("canvas");
    }
    const ctx = this.#measureCanvas.getContext("2d");
    if (!ctx) return 0;

    const fontStyle = computed.fontStyle || "normal";
    const fontWeight = computed.fontWeight || "400";
    const fontFamily = computed.fontFamily || "sans-serif";
    ctx.font = `${fontStyle} ${fontWeight} ${fontSize}px ${fontFamily}`;
    return ctx.measureText(text).width;
  }
}
