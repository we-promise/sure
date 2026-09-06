import { Controller } from "@hotwired/stimulus";
import * as d3 from "d3";
import {
  createChartTooltip,
  CHART_TOOLTIP_CONTEXT_CLASSES,
  CHART_TOOLTIP_VALUE_CLASSES,
} from "utils/chart_tooltip";

// Payoff comparison chart for a loan. Renders:
//   - Solid balance history from the schedule's start → today
//   - Two dashed forward lines from today: the original schedule's
//     remaining balance (neutral) and the actual-balance projection
//     (green if ahead of schedule, amber if behind)
//   - Today marker (vertical line + dot)
//
// Data shape passed via `data-loan-payoff-chart-data-value` matches
// Loan#payoff_chart_payload. Deliberately not a port of
// goal_projection_chart_controller.js -- that chart draws one projection
// line off a single on-track boolean; this draws two independently-dated
// forward lines, which is a different shape of problem.
export default class extends Controller {
  static values = {
    data: Object,
  };

  connect() {
    this._resize = this._draw.bind(this);
    window.addEventListener("resize", this._resize);
    // Container may have 0 width on initial connect (Turbo restoration,
    // hidden parent, etc). Re-draw whenever the box settles into a real
    // size. The first observer callback also performs the initial paint.
    if (typeof ResizeObserver !== "undefined") {
      this._observer = new ResizeObserver(() => this._draw());
      this._observer.observe(this.element);
    } else {
      this._draw();
    }
    this._onTurboRender = () => {
      if (!this.element.querySelector("svg")) this._draw();
    };
    document.addEventListener("turbo:render", this._onTurboRender);
    document.addEventListener("turbo:frame-load", this._onTurboRender);
  }

  disconnect() {
    window.removeEventListener("resize", this._resize);
    this._observer?.disconnect();
    if (this._onTurboRender) {
      document.removeEventListener("turbo:render", this._onTurboRender);
      document.removeEventListener("turbo:frame-load", this._onTurboRender);
    }
  }

  _draw() {
    const root = this.element;
    root.innerHTML = "";

    const data = this.dataValue || {};
    const width = root.clientWidth;
    const height = root.clientHeight;
    if (width <= 0 || height <= 0) return;

    const isDark = document.documentElement.getAttribute("data-theme") === "dark";
    const textPrimary = isDark ? "#ffffff" : "#171717";
    const textSecondary = isDark ? "#cfcfcf" : "#737373";
    const borderSubdued = isDark ? "rgba(255,255,255,0.15)" : "rgba(0,0,0,0.10)";
    const containerBg = isDark ? "#0a0a0a" : "#ffffff";
    const accentColor = data.ahead ? "var(--color-green-600)" : "var(--color-yellow-600)";

    // Date-only payload strings ("YYYY-MM-DD") parse as UTC midnight in
    // `new Date(str)`, which shifts displayed days back one for users west
    // of Greenwich. Parse components so points sit on local-midnight.
    const parseLocalDate = (s) => {
      if (!s) return null;
      const [ y, m, d ] = s.split("-").map(Number);
      return new Date(y, m - 1, d);
    };
    const toPoint = (p) => ({ date: parseLocalDate(p.date), balance: p.balance });

    const today = parseLocalDate(data.today);
    const currentBalancePoint = data.current_balance ? toPoint(data.current_balance) : { date: today, balance: 0 };

    const historySeries = (data.scheduled_history || []).map(toPoint);
    // The contracted trajectory's last known point before today -- anchors
    // originalSeries below so that purely-contracted line stays independent
    // of the live balance even when it's diverged (extra payments made).
    // Falls back to currentBalancePoint only for a brand-new loan with no
    // scheduled history yet -- there's no contracted "before" to anchor to.
    const lastContractedPoint = historySeries.length > 0 ? historySeries[historySeries.length - 1] : currentBalancePoint;
    // Close the solid line at (today, currentBalance) -- the actual, live
    // balance, which can differ from the last scheduled payment's balance
    // when extra payments were made. That gap is deliberate: it's the
    // visual signal of the extra payment.
    historySeries.push(currentBalancePoint);

    // originalSeries is the "if you'd only ever made the contracted
    // payment" reference -- it must stay independent of the live balance,
    // so it continues from the contracted trajectory's own last point, not
    // currentBalancePoint (unlike acceleratedSeries below, which is
    // *defined* as starting from today's real balance).
    const originalSeries = [lastContractedPoint, ...(data.original_projection || []).map(toPoint)];
    const acceleratedSeries = [currentBalancePoint, ...(data.accelerated_projection || []).map(toPoint)];

    if (historySeries.length < 2 && originalSeries.length < 2 && acceleratedSeries.length < 2) return;

    const allDates = [
      ...historySeries.map((d) => d.date),
      ...originalSeries.map((d) => d.date),
      ...acceleratedSeries.map((d) => d.date),
    ];
    const allBalances = [
      ...historySeries.map((d) => d.balance),
      ...originalSeries.map((d) => d.balance),
      ...acceleratedSeries.map((d) => d.balance),
    ];
    const startDate = d3.min(allDates);
    const endDate = d3.max(allDates);
    const yMax = Math.max(d3.max(allBalances) || 0, 1) * 1.05;

    // Reserve gutter for y-axis labels when there's room. Mobile (< 320)
    // keeps the tighter left margin and skips the y-axis entirely.
    const yAxisVisible = width - 16 - 24 >= 320;
    const margin = { top: 28, right: 24, bottom: 28, left: yAxisVisible ? 44 : 16 };
    const innerWidth = width - margin.left - margin.right;
    const innerHeight = height - margin.top - margin.bottom;

    const x = d3.scaleTime().domain([startDate, endDate]).range([margin.left, margin.left + innerWidth]);
    const y = d3.scaleLinear().domain([0, yMax]).range([margin.top + innerHeight, margin.top]);

    const svg = d3
      .select(root)
      .append("svg")
      .attr("width", width)
      .attr("height", height)
      .attr("viewBox", `0 0 ${width} ${height}`);

    // Server-built label/description (Loan#payoff_chart_payload) carry the
    // chart's actual figures, not just a generic title -- the SVG's own
    // <desc> is the only content assistive tech gets from it; the visible
    // sr-only paragraph below the chart (see the schedule tab partial)
    // duplicates aria_description as real DOM text so it doesn't depend on
    // desc support either.
    const descId = `payoff-chart-desc-${this._id()}`;
    svg.attr("role", "img").attr("aria-label", data.aria_label || "Loan payoff comparison chart");
    svg.append("desc").attr("id", descId).text(data.aria_description || "");
    svg.attr("aria-describedby", descId);

    const defs = svg.append("defs");
    const gradient = defs
      .append("linearGradient")
      .attr("id", `payoff-history-fill-${this._id()}`)
      .attr("x1", 0).attr("y1", 0).attr("x2", 0).attr("y2", 1);
    gradient.append("stop").attr("offset", "0%").attr("stop-color", textPrimary).attr("stop-opacity", 0.18);
    gradient.append("stop").attr("offset", "100%").attr("stop-color", textPrimary).attr("stop-opacity", 0);

    const clipId = `payoff-plot-clip-${this._id()}`;
    defs
      .append("clipPath")
      .attr("id", clipId)
      .append("rect")
      .attr("x", margin.left - 2)
      .attr("y", margin.top)
      .attr("width", innerWidth + 4)
      .attr("height", innerHeight);
    const plotClip = `url(#${clipId})`;

    if (yAxisVisible) {
      y.ticks(3).forEach((tickValue) => {
        svg
          .append("line")
          .attr("x1", margin.left)
          .attr("x2", margin.left + innerWidth)
          .attr("y1", y(tickValue))
          .attr("y2", y(tickValue))
          .attr("stroke", borderSubdued)
          .attr("stroke-width", 1);
        svg
          .append("text")
          .attr("x", margin.left - 6)
          .attr("y", y(tickValue) + 3)
          .attr("text-anchor", "end")
          .attr("font-size", 12)
          .attr("fill", textSecondary)
          .text(this._fmtMoneyShort(tickValue));
      });
    }

    const area = d3
      .area()
      .x((d) => x(d.date))
      .y0(margin.top + innerHeight)
      .y1((d) => y(d.balance))
      .curve(d3.curveMonotoneX);

    const line = d3
      .line()
      .x((d) => x(d.date))
      .y((d) => y(d.balance))
      .curve(d3.curveMonotoneX);

    if (historySeries.length > 1) {
      svg
        .append("path")
        .datum(historySeries)
        .attr("fill", `url(#payoff-history-fill-${this._id()})`)
        .attr("clip-path", plotClip)
        .attr("d", area);

      svg
        .append("path")
        .datum(historySeries)
        .attr("fill", "none")
        .attr("stroke", textPrimary)
        .attr("stroke-width", 2)
        .attr("stroke-linejoin", "round")
        .attr("stroke-linecap", "round")
        .attr("clip-path", plotClip)
        .attr("d", line);
    }

    if (originalSeries.length > 1) {
      svg
        .append("path")
        .datum(originalSeries)
        .attr("fill", "none")
        .attr("stroke", textSecondary)
        .attr("stroke-width", 1.5)
        .attr("stroke-linecap", "round")
        .attr("stroke-dasharray", "3 4")
        .attr("opacity", 0.7)
        .attr("d", line);
    }

    if (acceleratedSeries.length > 1) {
      svg
        .append("path")
        .datum(acceleratedSeries)
        .attr("fill", "none")
        .attr("stroke", accentColor)
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
      .attr("cy", y(currentBalancePoint.balance))
      .attr("r", 4)
      .attr("fill", textPrimary)
      .attr("stroke", containerBg)
      .attr("stroke-width", 2);

    if (innerWidth >= 320) {
      svg
        .append("text")
        .attr("x", x(today))
        .attr("y", margin.top - 4)
        .attr("text-anchor", "middle")
        .attr("font-size", 12)
        .attr("fill", textSecondary)
        .text((data.labels?.today) || "Today");
    }

    const tickFmt = d3.timeFormat("%b %Y");
    const tickCount = Math.min(5, Math.max(2, Math.round(innerWidth / 80)));
    const tickGroup = svg.append("g");
    tickGroup
      .selectAll("text")
      .data(x.ticks(tickCount))
      .enter()
      .append("text")
      .attr("x", (d) => x(d))
      .attr("y", height - 8)
      .attr("text-anchor", "middle")
      .attr("font-size", 12)
      .attr("fill", textSecondary)
      .text((d) => tickFmt(d));
    const tickNodes = tickGroup.selectAll("text").nodes();
    for (let i = tickNodes.length - 1; i > 0; i--) {
      if (tickNodes[i].textContent === tickNodes[i - 1].textContent) {
        tickNodes[i].remove();
      }
    }

    // Hover interactivity: crosshair + tooltip on pointermove. Past dates
    // show the single history value; future dates show both forward lines
    // side by side, since comparing them is the point of this chart.
    const crosshair = svg
      .append("line")
      .attr("y1", margin.top)
      .attr("y2", margin.top + innerHeight)
      .attr("stroke", textSecondary)
      .attr("stroke-width", 1)
      .attr("stroke-dasharray", "2 2")
      .attr("pointer-events", "none")
      .style("display", "none");

    if (getComputedStyle(root).position === "static") root.style.position = "relative";
    const tooltip = createChartTooltip(root);
    tooltip.style.transition = "left 80ms ease-out, top 80ms ease-out";
    const tooltipDate = document.createElement("div");
    tooltipDate.className = CHART_TOOLTIP_CONTEXT_CLASSES;
    const tooltipOriginal = document.createElement("div");
    tooltipOriginal.className = CHART_TOOLTIP_VALUE_CLASSES;
    const tooltipAccelerated = document.createElement("div");
    tooltipAccelerated.className = `${CHART_TOOLTIP_VALUE_CLASSES} mt-0.5`;
    tooltip.replaceChildren(tooltipDate, tooltipOriginal, tooltipAccelerated);

    const bisectDate = d3.bisector((d) => d.date).left;
    const dateFmt = d3.timeFormat("%b %d, %Y");
    const todayTs = today.getTime();

    const nearestValue = (series, targetDate) => {
      if (series.length === 0) return null;
      const i = bisectDate(series, targetDate);
      const a = series[Math.max(0, i - 1)];
      const b = series[Math.min(series.length - 1, i)];
      if (!a) return b;
      if (!b) return a;
      return Math.abs(targetDate - a.date) <= Math.abs(b.date - targetDate) ? a : b;
    };

    const showAt = (xPos) => {
      const hoverDate = x.invert(xPos);
      const isFuture = hoverDate.getTime() >= todayTs;
      const hoverX = x(hoverDate);
      crosshair.attr("x1", hoverX).attr("x2", hoverX).style("display", null);
      tooltipDate.textContent = dateFmt(hoverDate);

      if (isFuture) {
        const originalPoint = nearestValue(originalSeries, hoverDate);
        const acceleratedPoint = nearestValue(acceleratedSeries, hoverDate);
        tooltipOriginal.textContent = originalPoint
          ? `${(data.labels?.original) || "Original"}: ${this._fmtMoney(originalPoint.balance)}`
          : "";
        tooltipOriginal.style.display = originalPoint ? "" : "none";
        tooltipAccelerated.textContent = acceleratedPoint
          ? `${(data.labels?.accelerated) || "Projected"}: ${this._fmtMoney(acceleratedPoint.balance)}`
          : "";
        tooltipAccelerated.style.display = acceleratedPoint ? "" : "none";
      } else {
        const historyPoint = nearestValue(historySeries, hoverDate);
        tooltipOriginal.textContent = historyPoint
          ? `${(data.labels?.scheduled) || "Scheduled"}: ${this._fmtMoney(historyPoint.balance)}`
          : "";
        tooltipOriginal.style.display = historyPoint ? "" : "none";
        tooltipAccelerated.style.display = "none";
      }

      tooltip.style.display = "block";
      const tipRect = tooltip.getBoundingClientRect();
      const left = Math.min(width - tipRect.width - 4, Math.max(4, xPos + 12));
      const top = Math.max(4, margin.top);
      tooltip.style.left = `${left}px`;
      tooltip.style.top = `${top}px`;
    };

    const hide = () => {
      crosshair.style("display", "none");
      tooltip.style.display = "none";
    };

    const overlay = svg
      .append("rect")
      .attr("x", margin.left)
      .attr("y", margin.top)
      .attr("width", innerWidth)
      .attr("height", innerHeight)
      .attr("fill", "transparent")
      .style("cursor", "crosshair");

    overlay.on("pointermove", (event) => {
      const [ mx ] = d3.pointer(event);
      showAt(mx);
    });
    overlay.on("pointerleave", hide);

    // Keyboard equivalent of the hover tooltip above -- the visible sr-only
    // paragraph next to this chart (see the Schedule tab partial) already
    // gives screen-reader users the key figures as real text, but only a
    // pointer could previously inspect any *other* point on the lines.
    // Arrow keys step through the same nearest-point data a hover would
    // show, landing on each series' real monthly dates rather than an
    // arbitrary pixel -- useful past pure screen-reader use too, for
    // keyboard/low-vision users who can't drive a mouse precisely enough to
    // scrub the chart. tooltip's aria-live announces each step's content.
    tooltip.setAttribute("role", "status");
    tooltip.setAttribute("aria-live", "polite");

    const stopDates = Array.from(
      new Set([ ...historySeries, ...originalSeries, ...acceleratedSeries ].map((d) => d.date.getTime()))
    ).sort((a, b) => a - b).map((t) => new Date(t));

    if (stopDates.length > 0) {
      svg.attr("tabindex", 0);
      let focusedIndex = null;

      svg.on("keydown", (event) => {
        if (![ "ArrowLeft", "ArrowRight", "Home", "End", "Escape" ].includes(event.key)) return;
        event.preventDefault();

        if (event.key === "Escape") {
          focusedIndex = null;
          hide();
          return;
        }

        if (focusedIndex === null) {
          focusedIndex = event.key === "ArrowLeft" ? stopDates.length - 1 : 0;
        } else if (event.key === "ArrowLeft") {
          focusedIndex = Math.max(0, focusedIndex - 1);
        } else if (event.key === "ArrowRight") {
          focusedIndex = Math.min(stopDates.length - 1, focusedIndex + 1);
        } else if (event.key === "Home") {
          focusedIndex = 0;
        } else {
          focusedIndex = stopDates.length - 1;
        }

        showAt(x(stopDates[focusedIndex]));
      });

      svg.on("blur", () => {
        focusedIndex = null;
        hide();
      });
    }
  }

  _fmtMoney(amount) {
    try {
      return new Intl.NumberFormat(undefined, {
        style: "currency",
        currency: this.dataValue?.currency || "USD",
        maximumFractionDigits: 0,
      }).format(amount);
    } catch {
      return `$${Math.round(amount).toLocaleString()}`;
    }
  }

  _fmtMoneyShort(amount) {
    const abs = Math.abs(amount);
    let value;
    if (abs >= 1_000_000) {
      value = `${(amount / 1_000_000).toFixed(1).replace(/\.0$/, "")}M`;
    } else if (abs >= 1_000) {
      value = `${(amount / 1_000).toFixed(1).replace(/\.0$/, "")}K`;
    } else {
      value = `${Math.round(amount).toLocaleString()}`;
    }
    return `${this._currencySymbol()}${value}`;
  }

  _currencySymbol() {
    try {
      const parts = new Intl.NumberFormat(undefined, {
        style: "currency",
        currency: this.dataValue?.currency || "USD",
        maximumFractionDigits: 0,
      }).formatToParts(0);
      return parts.find((p) => p.type === "currency")?.value || "$";
    } catch {
      return "$";
    }
  }

  _id() {
    if (!this._cachedId) {
      this._cachedId = Math.random().toString(36).slice(2, 8);
    }
    return this._cachedId;
  }
}
