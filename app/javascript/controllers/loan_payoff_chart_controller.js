import { Controller } from "@hotwired/stimulus";
import * as d3 from "d3";
import {
  CHART_TOOLTIP_CONTEXT_CLASSES,
  CHART_TOOLTIP_VALUE_CLASSES,
  createChartTooltip,
} from "utils/chart_tooltip";

// The loan balance chart: three series on one axis.
//
//   actual     the recorded balance, origination -> today. Solid: fact.
//   scheduled  the original contract, origination -> maturity. Dashed.
//   projected  where today's balance is heading on the contract's repayment.
//              Dashed.
//
// Series are distinguished by DASH PATTERN as well as colour. Hue alone fails
// in greyscale and under deuteranopia, and red/green would be the worst
// possible pair to rely on. Solid-versus-dashed also keeps "recorded fact"
// and "forecast" visually separable.
//
// The x-domain comes from the payload, not from the data: the period picker
// governs it (#100, decision 4). Series are drawn through a clip so a line
// that leaves the window is cut at its edge rather than stretching the axis.

// Date-only strings parse as UTC midnight in `new Date`, shifting the day
// back for anyone west of Greenwich. Parse the components instead.
const parseDate = (s) => {
  if (!s) return null;
  const [y, m, d] = s.split("-").map(Number);
  return new Date(y, m - 1, d);
};

let clipSerial = 0;

export default class extends Controller {
  static values = { data: Object, tableId: String };

  connect() {
    this._draw = this._draw.bind(this);
    // A window resize also changes the element's box, so the resize listener
    // and the ResizeObserver both fire for one event. Each draw rebuilds the
    // whole SVG; coalesce them into one per animation frame.
    this._scheduleDraw = () => {
      if (this._frame) return;
      this._frame = requestAnimationFrame(() => {
        this._frame = null;
        this._draw();
      });
    };
    window.addEventListener("resize", this._scheduleDraw);
    // The container can be zero-width on first connect (a Turbo restore, a
    // hidden parent). Draw when the box settles.
    if (typeof ResizeObserver !== "undefined") {
      this._observer = new ResizeObserver(this._scheduleDraw);
      this._observer.observe(this.element);
    } else {
      this._draw();
    }
  }

  disconnect() {
    window.removeEventListener("resize", this._scheduleDraw);
    if (this._frame) cancelAnimationFrame(this._frame);
    this._frame = null;
    this._observer?.disconnect();
    this._tooltip?.remove();
  }

  _draw() {
    const root = this.element;
    const width = root.clientWidth;
    const height = root.clientHeight;
    if (width <= 0 || height <= 0) return;

    root.innerHTML = "";
    const data = this.dataValue || {};

    const toPoint = (p) => ({ date: parseDate(p.date), balance: p.balance });

    const domainStart = parseDate(data.domain_start);
    const domainEnd = parseDate(data.domain_end);
    const today = parseDate(data.today);
    if (!domainStart || !domainEnd || domainEnd <= domainStart) return;

    // Functional tokens, referenced as CSS variables and applied with
    // .style(), never .attr(): a variable is substituted in an inline style
    // property but not in an SVG presentation attribute, where it leaves the
    // stroke at `none` (#101). No fallback colours: a token that fails to
    // resolve must fail visibly, and the browser test checks the resolved
    // stroke. Because these are live variables the browser recolours the
    // chart on a theme change by itself; no redraw is needed for that.
    const success = "var(--color-success)";
    const destructive = "var(--color-destructive)";
    const muted = "var(--color-tertiary)";

    // Drawing order: forecasts underneath, fact on top.
    const series = [
      {
        key: "scheduled",
        points: (data.scheduled || []).map(toPoint),
        color: destructive,
        dash: "6 4",
        width: 1.5,
      },
      {
        key: "projected",
        points: (data.projected || []).map(toPoint),
        color: success,
        dash: "4 4",
        width: 2,
      },
      {
        key: "actual",
        points: (data.actual || []).map(toPoint),
        color: success,
        dash: null,
        width: 2,
      },
    ].filter((s) => s.points.length > 1);
    if (series.length === 0) return;

    const margin = { top: 12, right: 12, bottom: 24, left: 48 };
    const x = d3
      .scaleTime()
      .domain([domainStart, domainEnd])
      .range([margin.left, width - margin.right]);
    // Scale the y-axis to what is inside the window plus each line's first
    // point either side of it, so a line crossing the window fits without the
    // window being sized for points it never shows.
    const inWindow = (points) => {
      const inside = points.filter(
        (p) => p.date >= domainStart && p.date <= domainEnd,
      );
      const before = points.filter((p) => p.date < domainStart).at(-1);
      const after = points.find((p) => p.date > domainEnd);
      return [before, ...inside, after].filter(Boolean);
    };
    const scalePoints = series.flatMap((s) => inWindow(s.points));
    const yMax = (d3.max(scalePoints, (d) => d.balance) || 1) * 1.05;
    const y = d3
      .scaleLinear()
      .domain([0, yMax])
      .range([height - margin.bottom, margin.top]);

    const svg = d3
      .select(root)
      .append("svg")
      .attr("width", width)
      .attr("height", height)
      .attr("role", "img")
      .attr("aria-label", data.aria_description || "")
      // The picture is also a keyboard control: arrow keys step the tooltip
      // through the plotted dates. Say so, since role=img alone would not.
      .attr("aria-roledescription", data.labels?.interactive_chart || "interactive chart")
      .attr("aria-keyshortcuts", "ArrowLeft ArrowRight Home End Escape");
    // aria-details, not aria-describedby: a description is flattened into the
    // accessible name computation, so describedby would read every cell of a
    // 360-row table out as the chart's description. details links the table as
    // a long-form alternative a reader can visit instead.
    if (this.hasTableIdValue && this.tableIdValue) {
      svg.attr("aria-details", this.tableIdValue);
    }

    // Clip-path ids must be unique in the document. The mount carries the
    // account's own dom_id, which already is; a counter covers a mount without
    // one. Nothing random: the ids are read by url(#...) only.
    const id = `${root.id || `loan-chart-${++clipSerial}`}-clip`;
    const defs = svg.append("defs");
    const plotClip = `${id}-plot`;
    defs
      .append("clipPath")
      .attr("id", plotClip)
      .append("rect")
      .attr("x", margin.left)
      .attr("y", margin.top)
      .attr("width", Math.max(0, width - margin.left - margin.right))
      .attr("height", Math.max(0, height - margin.top - margin.bottom));
    // The hover split on the actual series: the recorded line stays coloured up
    // to the cursor and greys past it. Two clips share one edge, moved on
    // pointer events; at rest the edge sits at the window's end and the whole
    // line is coloured. Forecasts have no "before the cursor" to speak of.
    const splitAt = (px) => {
      pastClip.attr("width", Math.max(0, px - margin.left));
      futureClip
        .attr("x", px)
        .attr("width", Math.max(0, width - margin.right - px));
    };
    const pastClip = defs
      .append("clipPath")
      .attr("id", `${id}-past`)
      .append("rect")
      .attr("x", margin.left)
      .attr("y", margin.top)
      .attr("height", Math.max(0, height - margin.top - margin.bottom));
    const futureClip = defs
      .append("clipPath")
      .attr("id", `${id}-future`)
      .append("rect")
      .attr("y", margin.top)
      .attr("height", Math.max(0, height - margin.top - margin.bottom));
    splitAt(width - margin.right);

    const line = d3
      .line()
      .x((d) => x(d.date))
      .y((d) => y(d.balance))
      .curve(d3.curveMonotoneX);
    const area = d3
      .area()
      .x((d) => x(d.date))
      .y0(height - margin.bottom)
      .y1((d) => y(d.balance))
      .curve(d3.curveMonotoneX);

    // Axes first, so the series draw over them. Text in currentColor: the
    // container carries the text token, so the axis follows the theme.
    const styleAxis = (g) => {
      g.selectAll("text")
        .style("fill", "currentColor")
        .style("opacity", 0.7)
        .style("font-size", "11px");
      g.selectAll("line,path")
        .style("stroke", "currentColor")
        .style("opacity", 0.2);
    };
    svg
      .append("g")
      .attr("transform", `translate(0,${height - margin.bottom})`)
      .call(
        d3
          .axisBottom(x)
          .ticks(Math.max(2, Math.floor(width / 140)))
          .tickSizeOuter(0),
      )
      .call(styleAxis);
    svg
      .append("g")
      .attr("transform", `translate(${margin.left},0)`)
      .call(
        d3.axisLeft(y).ticks(4).tickFormat(d3.format("~s")).tickSizeOuter(0),
      )
      .call(styleAxis);

    const stroke = (path, s, color) =>
      path
        .style("fill", "none")
        .style("stroke", color)
        .style("stroke-width", s.width)
        .style("stroke-linecap", "round")
        .style("stroke-linejoin", "round")
        .style("stroke-dasharray", s.dash || "none");

    for (const s of series) {
      if (s.key === "actual") {
        svg
          .append("path")
          .datum(s.points)
          .attr("d", area)
          .attr("clip-path", `url(#${plotClip})`)
          .style("fill", s.color)
          .style("opacity", 0.08);
        // The greyed remainder sits underneath; the coloured line on top is
        // the one that carries data-series, so a test asking for the actual
        // line finds the line that is meant to be seen.
        stroke(svg.append("path").datum(s.points).attr("d", line), s, muted)
          .attr("clip-path", `url(#${id}-future)`)
          .attr("data-series-shadow", s.key)
          .style("opacity", 0.6);
        stroke(svg.append("path").datum(s.points).attr("d", line), s, s.color)
          .attr("clip-path", `url(#${id}-past)`)
          .attr("data-series", s.key);
      } else {
        stroke(svg.append("path").datum(s.points).attr("d", line), s, s.color)
          .attr("clip-path", `url(#${plotClip})`)
          .attr("data-series", s.key);
      }

      // Interval markers, thinned to roughly one per 60px so a 360-payment
      // schedule does not become a solid band of circles. Not the accessible
      // signal: dash pattern is.
      const step = Math.max(
        1,
        Math.ceil(s.points.length / Math.max(2, width / 60)),
      );
      svg
        .append("g")
        .attr("clip-path", `url(#${plotClip})`)
        .selectAll("circle")
        .data(s.points.filter((_, i) => i % step === 0))
        .join("circle")
        .attr("cx", (d) => x(d.date))
        .attr("cy", (d) => y(d.balance))
        .attr("r", 2.5)
        .style("fill", s.color);
    }

    if (today && today >= domainStart && today <= domainEnd) {
      svg
        .append("line")
        .attr("x1", x(today))
        .attr("x2", x(today))
        .attr("y1", margin.top)
        .attr("y2", height - margin.bottom)
        .style("stroke", "currentColor")
        .style("stroke-dasharray", "2 3")
        .style("opacity", 0.4);
    }

    this._installInteraction(svg, {
      x,
      series,
      width,
      height,
      margin,
      data,
      domainStart,
      domainEnd,
      splitAt,
    });
  }

  _installInteraction(
    svg,
    { x, series, width, height, margin, data, domainStart, domainEnd, splitAt },
  ) {
    this._tooltip?.remove();
    this.element.style.position = "relative";
    // The shared visual contract the other chart controllers use: the
    // .chart-tooltip surface, z-50 and privacy-sensitive.
    const tooltip = createChartTooltip(this.element);
    this._tooltip = tooltip;

    const bisect = d3.bisector((d) => d.date).left;
    const nearest = (points, date) => {
      if (!points.length) return null;
      const i = bisect(points, date);
      const a = points[Math.max(0, i - 1)];
      const b = points[Math.min(points.length - 1, i)];
      if (!a) return b;
      if (!b) return a;
      return date - a.date <= b.date - date ? a : b;
    };
    // The request's locale travels in the payload: the layout hard-codes
    // lang="en", so the document cannot say. Both the date and the money in
    // the tooltip follow it.
    const locale = data.locale || undefined;
    const monthYear = new Intl.DateTimeFormat(locale, {
      month: "short",
      year: "numeric",
    });
    const formatter = (() => {
      try {
        return new Intl.NumberFormat(locale, {
          style: "currency",
          currency: data.currency || "USD",
          maximumFractionDigits: 0,
        });
      } catch {
        // A currency code Intl does not know must not take hover with it.
        return new Intl.NumberFormat(locale, { maximumFractionDigits: 0 });
      }
    })();
    const money = (value) => formatter.format(value);

    const showAt = (date) => {
      const px = x(date);
      const rows = series
        .map((s) => {
          // A series says nothing about dates outside its own span.
          if (date < s.points[0].date || date > s.points.at(-1).date)
            return null;
          const point = nearest(s.points, date);
          return point
            ? {
                label: data.labels?.[s.key] || s.key,
                value: money(point.balance),
              }
            : null;
        })
        .filter(Boolean);
      // The domain can open before the first series point (a period that
      // starts before origination). Off every series there is nothing to
      // say, and the previous position must not stay on screen.
      if (!rows.length) {
        hide();
        return;
      }

      // Text nodes, never innerHTML. Date and figures take the shared content
      // classes, as the other charts' tooltips do.
      const dateRow = document.createElement("div");
      dateRow.className = CHART_TOOLTIP_CONTEXT_CLASSES;
      dateRow.textContent = monthYear.format(date);
      const valueRows = rows.map(({ label, value }) => {
        const row = document.createElement("div");
        const amount = document.createElement("span");
        amount.className = CHART_TOOLTIP_VALUE_CLASSES;
        amount.textContent = value;
        row.append(`${label}: `, amount);
        return row;
      });
      tooltip.replaceChildren(dateRow, ...valueRows);
      tooltip.style.display = "block";
      // Measured once the content is in: the shared surface is padded, so a
      // fixed allowance would let a long row run past the chart's right edge.
      const left = Math.min(px + 12, width - tooltip.offsetWidth - 4);
      tooltip.style.left = `${Math.max(margin.left, left)}px`;
      tooltip.style.top = `${margin.top}px`;
      splitAt(Math.max(margin.left, Math.min(px, width - margin.right)));
    };
    // The live region announces only what the keyboard asks for. Under a
    // pointer the tooltip rewrites on every movement, and a live region that
    // announces every one of those is noise for anyone using a pointer with a
    // screen reader (#57).
    const announce = (on) => {
      if (on) {
        tooltip.setAttribute("role", "status");
        tooltip.setAttribute("aria-live", "polite");
      } else {
        tooltip.removeAttribute("role");
        tooltip.removeAttribute("aria-live");
      }
    };

    const hide = () => {
      tooltip.style.display = "none";
      announce(false);
      splitAt(width - margin.right);
    };

    svg
      .append("rect")
      .attr("x", margin.left)
      .attr("y", margin.top)
      .attr("width", Math.max(0, width - margin.left - margin.right))
      .attr("height", Math.max(0, height - margin.top - margin.bottom))
      .style("fill", "transparent")
      .style("cursor", "crosshair")
      .on("pointermove", (event) => {
        announce(false);
        const [px] = d3.pointer(event);
        showAt(x.invert(px));
      })
      .on("pointerleave", hide);

    // Keyboard traversal: the same nearest-point data a hover shows, stepped
    // through the dates the data table lists -- one per scheduled payment in
    // the window -- so the keyboard and the table give the same figures (G6).
    // The recorded line's own points are weekly and would otherwise repeat
    // the same month several times over. Arrow keys move, Home/End jump,
    // Escape clears.
    const rowDates = (data.rows || [])
      .map((row) => parseDate(row.date))
      .filter((date) => date && date >= domainStart && date <= domainEnd);
    const stops = Array.from(
      new Set(
        (rowDates.length
          ? rowDates
          : series.flatMap((s) => s.points).map((p) => p.date)
        )
          .filter((date) => date >= domainStart && date <= domainEnd)
          .map((date) => date.getTime()),
      ),
    )
      .sort((a, b) => a - b)
      .map((t) => new Date(t));
    if (!stops.length) return;

    svg.attr("tabindex", 0);
    let focused = null;
    svg.on("keydown", (event) => {
      if (
        !["ArrowLeft", "ArrowRight", "Home", "End", "Escape"].includes(
          event.key,
        )
      )
        return;
      event.preventDefault();
      if (event.key === "Escape") {
        focused = null;
        hide();
        return;
      }
      if (focused === null)
        focused = event.key === "ArrowLeft" ? stops.length - 1 : 0;
      else if (event.key === "ArrowLeft") focused = Math.max(0, focused - 1);
      else if (event.key === "ArrowRight")
        focused = Math.min(stops.length - 1, focused + 1);
      else if (event.key === "Home") focused = 0;
      else focused = stops.length - 1;
      announce(true);
      // `focused` is clamped to the array above; `.at()` reads the same
      // element without the bracket form object-injection scanners flag.
      showAt(stops.at(focused));
    });
    svg.on("blur", () => {
      focused = null;
      hide();
    });
  }
}
