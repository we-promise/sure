import { Controller } from "@hotwired/stimulus";
import * as d3 from "d3";

// Connects to data-controller="donut-chart"
export default class extends Controller {
  static targets = ["chartContainer", "contentContainer", "defaultContent", "categoryRow", "toggleButton", "categoryAmount", "categoryPercentage"];
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
  #hiddenSegments = new Set();

  connect() {
    this.#draw();
    document.addEventListener("turbo:load", this.#redraw);
    this.element.addEventListener("mouseleave", this.#clearSegmentHover);
  }

  disconnect() {
    this.#teardown();
    document.removeEventListener("turbo:load", this.#redraw);
    this.element.removeEventListener("mouseleave", this.#clearSegmentHover);
  }

  get #data() {
    const visibleSegments = this.segmentsValue.filter(
      (s) => s.amount > 0 && !this.#hiddenSegments.has(s.id)
    );

    const totalPieValue = visibleSegments.reduce(
      (acc, s) => acc + Number(s.amount),
      0,
    );

    // Overage is always first segment, unused is always last segment
    return visibleSegments
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
      .on("mouseleave", () => {
        clearTimeout(hoverTimeout);
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
    if (!segment.name || !this.startDateValue || !this.endDateValue) return;

    const segmentName = encodeURIComponent(segment.name);
    const startDate = this.startDateValue;
    const endDate = this.endDateValue;

    const url = `/transactions?q[categories][]=${segmentName}&q[start_date]=${startDate}&q[end_date]=${endDate}`;
    window.location.href = url;
  }

  // Public methods for external highlighting (e.g., from category list hover)
  highlightSegment(event) {
    const segmentId = event.currentTarget.dataset.categoryId;

    // Don't highlight if segment is hidden
    if (this.#hiddenSegments.has(segmentId)) return;

    const template = this.element.querySelector(`#segment_${segmentId}`);
    const unusedSegmentId = this.unusedSegmentIdValue;

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

    // Update center content
    if (template) {
      this.defaultContentTarget.classList.add("hidden");
      template.classList.remove("hidden");
    }
  }

  unhighlightSegment() {
    // Use cached selection if available for better performance
    const paths = this.#visiblePaths || d3.select(this.chartContainerTarget).selectAll("path.visible-path");

    // Restore original segment colors
    paths
      .attr("fill", function () {
        return this.dataset.originalColor;
      })
      .style("opacity", null);

    // Restore default content
    this.defaultContentTarget.classList.remove("hidden");
    for (const child of this.contentContainerTarget.children) {
      if (child !== this.defaultContentTarget) {
        child.classList.add("hidden");
      }
    }
  }

  toggleSegment(event) {
    event.preventDefault();
    event.stopPropagation();

    const button = event.currentTarget;
    const segmentId = button.dataset.categoryId;
    const originalColor = button.dataset.categoryColor;
    const isHidden = this.#hiddenSegments.has(segmentId);

    if (isHidden) {
      // Show the segment
      this.#hiddenSegments.delete(segmentId);
      this.#updateToggleButtonStyle(button, originalColor, false);
      this.#updateCategoryRowStyle(segmentId, false);
    } else {
      // Hide the segment
      this.#hiddenSegments.add(segmentId);
      this.#updateToggleButtonStyle(button, originalColor, true);
      this.#updateCategoryRowStyle(segmentId, true);
    }

    // Redraw the chart and update totals
    this.#redraw();
    this.#updateDefaultContent();
  }

  #updateToggleButtonStyle(button, originalColor, isHidden) {
    const grayColor = "#9ca3af";
    const color = isHidden ? grayColor : originalColor;

    button.style.backgroundColor = `color-mix(in oklab, ${color} 10%, transparent)`;
    button.style.borderColor = `color-mix(in oklab, ${color} 10%, transparent)`;
    button.style.color = color;
  }

  #updateCategoryRowStyle(segmentId, isHidden) {
    const row = this.categoryRowTargets.find(r => r.dataset.categoryId === segmentId);
    if (row) {
      if (isHidden) {
        row.classList.add("opacity-50");
      } else {
        row.classList.remove("opacity-50");
      }
    }

    // Update amount and percentage styles
    const amount = this.categoryAmountTargets.find(a => a.dataset.categoryId === segmentId);
    const percentage = this.categoryPercentageTargets.find(p => p.dataset.categoryId === segmentId);

    if (amount) {
      if (isHidden) {
        amount.classList.add("line-through", "text-secondary");
        amount.classList.remove("text-primary");
      } else {
        amount.classList.remove("line-through", "text-secondary");
        amount.classList.add("text-primary");
      }
    }

    if (percentage) {
      if (isHidden) {
        percentage.classList.add("line-through");
      } else {
        percentage.classList.remove("line-through");
      }
    }
  }

  #updateDefaultContent() {
    // Calculate new total from visible segments
    const visibleSegments = this.segmentsValue.filter(
      (s) => s.amount > 0 && !this.#hiddenSegments.has(s.id)
    );

    const newTotal = visibleSegments.reduce((acc, s) => acc + Number(s.amount), 0);

    // Update the total display in default content
    const totalElement = this.defaultContentTarget.querySelector(".text-3xl");
    if (totalElement && this.segmentsValue.length > 0) {
      const currency = this.segmentsValue[0].currency || "USD";
      const symbol = this.segmentsValue[0].currency_symbol || "$";
      totalElement.textContent = `${symbol}${newTotal.toLocaleString()}`;
    }
  }
}
