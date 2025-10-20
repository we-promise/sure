import { Controller } from "@hotwired/stimulus";
import * as d3 from "d3";

// Connects to data-controller="outflows-donut-chart"
export default class extends Controller {
  static targets = ["chartContainer", "contentContainer", "defaultContent"];
  static values = {
    categories: { type: Array, default: [] },
    currencySymbol: String,
    startDate: String,
    endDate: String,
    segmentHeight: { type: Number, default: 5 },
    segmentOpacity: { type: Number, default: 0.9 },
  };

  #viewBoxSize = 100;
  #minSegmentAngle = 0.05;
  #visiblePaths = null;

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
      .attr("viewBox", `0 0 ${this.#viewBoxSize} ${this.#viewBoxSize}`)
      .attr("preserveAspectRatio", "xMidYMid meet")
      .attr("class", "w-full h-full");

    const pie = d3
      .pie()
      .sortValues(null)
      .value((d) => d.amount);

    const arc = d3
      .arc()
      .innerRadius(this.#viewBoxSize / 2 - this.segmentHeightValue)
      .outerRadius(this.#viewBoxSize / 2)
      .cornerRadius(this.segmentHeightValue)
      .padAngle(this.#minSegmentAngle);

    // Create a larger arc for hover detection (extends further out)
    const hoverArc = d3
      .arc()
      .innerRadius(this.#viewBoxSize / 2 - this.segmentHeightValue - 3)
      .outerRadius(this.#viewBoxSize / 2 + 3)
      .padAngle(this.#minSegmentAngle);

    const g = svg
      .append("g")
      .attr(
        "transform",
        `translate(${this.#viewBoxSize / 2}, ${this.#viewBoxSize / 2})`,
      );

    const segmentGroups = g
      .selectAll("arc")
      .data(pie(this.categoriesValue))
      .enter()
      .append("g")
      .attr("class", "arc pointer-events-auto");

    // Add invisible hover paths with larger area
    segmentGroups
      .append("path")
      .attr("class", "hover-path")
      .attr("d", hoverArc)
      .attr("fill", "transparent")
      .attr("data-segment-id", (d) => d.data.id);

    // Add visible paths on top
    const segmentArcs = segmentGroups
      .append("path")
      .attr("class", "visible-path")
      .attr("data-segment-id", (d) => d.data.id)
      .attr("data-original-color", this.#transformRingColor)
      .attr("fill", this.#transformRingColor)
      .attr("d", arc)
      .style("pointer-events", "none"); // Disable pointer events on visible paths

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
        this.#handleClick(d.data);
      });
  }

  #transformRingColor = ({ data: { color } }) => {
    const reducedOpacityColor = d3.color(color);
    reducedOpacityColor.opacity = this.segmentOpacityValue;
    return reducedOpacityColor;
  };

  // Highlights segment and shows segment specific content (all other segments are grayed out)
  #handleSegmentHover(event) {
    const segmentId = event.target.dataset.segmentId;
    const template = this.element.querySelector(`#segment_${segmentId}`);

    if (!template) return;

    // Use cached selection instead of requerying
    this.#visiblePaths.attr("fill", function () {
      if (this.dataset.segmentId === segmentId) {
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

    // Use cached selection instead of requerying
    if (this.#visiblePaths) {
      this.#visiblePaths.attr("fill", function () {
        return this.dataset.originalColor;
      });
    }

    for (const child of this.contentContainerTarget.children) {
      if (child !== this.defaultContentTarget) {
        child.classList.add("hidden");
      }
    }
  };

  #handleClick(category) {
    const categoryName = encodeURIComponent(category.name);
    const startDate = this.startDateValue;
    const endDate = this.endDateValue;

    const url = `/transactions?q[categories][]=${categoryName}&q[start_date]=${startDate}&q[end_date]=${endDate}`;
    window.location.href = url;
  }

  highlightSegment(event) {
    const categoryId = event.currentTarget.dataset.categoryId;

    // Use cached selection instead of requerying
    if (this.#visiblePaths) {
      this.#visiblePaths.style("opacity", function() {
        return this.dataset.segmentId === categoryId ? 1 : 0.3;
      });
    }
  }

  unhighlightSegment() {
    // Use cached selection instead of requerying
    if (this.#visiblePaths) {
      this.#visiblePaths.style("opacity", this.segmentOpacityValue);
    }
  }
}
