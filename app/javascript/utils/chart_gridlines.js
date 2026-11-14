import * as d3 from "d3";
import { compactAxisFormatter } from "utils/chart_axis_labels";

// Shared y-axis gridlines for the money charts (spending, net worth, account
// balance): dashed horizontal rules with compact currency labels ($2K, $1.5M)
// in a gutter on the right. One implementation so every chart looks the same.
//
// Callers reserve a gutter on the right of their plot area for the labels
// (gridlineLabelGutter), draw this before the data so the lines sit behind it,
// and pass the plot's d3 y scale.

// Smallest right-hand margin (px) that holds the axis labels.
export const GRIDLINE_LABEL_GUTTER = 48;

const LABEL_FONT = "500 12px";
const LABEL_PADDING = 8; // distance from the plot edge to the label (tickPadding)
const LABEL_SLACK = 4; // breathing room past the widest label

let measureContext;

// Right margin that fits the widest of `labels` (never below the default), so
// long values like -$100.5K or 1,2 Mio. € are not clipped by the svg edge.
export function gridlineLabelGutter(labels, fontFamily = "sans-serif") {
  measureContext ??= document.createElement("canvas").getContext("2d");

  let widest = 0;
  if (measureContext) {
    measureContext.font = `${LABEL_FONT} ${fontFamily}`;
    widest = Math.max(
      0,
      ...labels.map((l) => measureContext.measureText(l).width),
    );
  } else {
    widest = Math.max(0, ...labels.map((l) => l.length * 7));
  }

  return Math.max(
    GRIDLINE_LABEL_GUTTER,
    Math.ceil(widest) + LABEL_PADDING + LABEL_SLACK,
  );
}

// d3's ~`count` round values across the scale's domain.
export function gridlineTicks(y, count = 4) {
  return y.ticks(count);
}

// Labels for `ticks`, with as many decimals as their spacing needs.
export function gridlineLabels(ticks, currency) {
  const format = compactAxisFormatter(ticks, currency);
  return ticks.map((t) => format(t));
}

// `group` is the plot-area <g>; `width` its inner width (lines span 0..width,
// labels sit just past the right edge). Lines go at `ticks` when given (a chart
// that fits its axis to the data supplies its own), else at d3's ~`tickCount`
// round values.
export function drawYGridlines(
  group,
  y,
  { width, currency, tickCount = 4, ticks = gridlineTicks(y, tickCount) },
) {
  const format = compactAxisFormatter(ticks, currency);

  group
    .append("g")
    .attr("class", "y-gridlines")
    .attr("pointer-events", "none")
    .selectAll("line")
    .data(ticks)
    .join("line")
    .attr("x1", 0)
    .attr("x2", width)
    .attr("y1", (d) => y(d))
    .attr("y2", (d) => y(d))
    .attr("stroke", "var(--color-gray-300)")
    .attr("stroke-dasharray", "4, 4")
    .attr("stroke-opacity", 0.6);

  group
    .append("g")
    .attr("class", "y-gridline-labels")
    .attr("transform", `translate(${width},0)`)
    .call(
      d3
        .axisRight(y)
        .tickValues(ticks)
        .tickSize(0)
        .tickPadding(LABEL_PADDING)
        .tickFormat((d) => format(d)),
    )
    .call((g) => g.select(".domain").remove())
    .selectAll("text")
    .attr("class", "text-secondary fill-current")
    .style("font-size", "12px")
    .style("font-weight", "500");
}
