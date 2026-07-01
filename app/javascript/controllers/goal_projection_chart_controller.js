import { Controller } from "@hotwired/stimulus";
import * as d3 from "d3";
import {
  createChartTooltip,
  CHART_TOOLTIP_CONTEXT_CLASSES,
  CHART_TOOLTIP_VALUE_CLASSES,
} from "utils/chart_tooltip";

// Projection chart for a goal. Renders:
//   - Saved area + line from goal creation → today (solid)
//   - Dashed projection line from today → target date (yellow if behind,
//     green if on track)
//   - Horizontal dashed target line with label
//   - Today marker (vertical line + dot)
//
// Data shape passed via `data-goal-projection-chart-data-value`
// matches Goal#projection_payload.
export default class extends Controller {
  static values = {
    data: Object,
    ariaLabel: String,
    ariaDescription: String,
    todayLabel: { type: String, default: "Today" },
    projectedTemplate: { type: String, default: "Projected: {amount}" },
    savedTemplate: { type: String, default: "Saved: {amount}" },
    targetRelationTemplate: { type: String, default: "{percent}% of {target} target" },
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
    // Repaint when the user toggles theme so SVG attributes (which bake
    // light/dark hex values at draw time) follow data-theme. Lives here
    // until theme_controller broadcasts a theme:change event upstream.
    if (typeof MutationObserver !== "undefined") {
      this._themeObserver = new MutationObserver((mutations) => {
        if (mutations.some((m) => m.attributeName === "data-theme")) this._draw();
      });
      this._themeObserver.observe(document.documentElement, {
        attributes: true,
        attributeFilter: ["data-theme"],
      });
    }
    // After a Turbo render (eg. after saving the goal from the edit modal
    // and redirecting back to show), the chart container can be left empty
    // its children may be wiped by the morph even though connect() was
    // already called, and ResizeObserver doesn't fire because the size
    // didn't change. Listen for the render event so we redraw when needed.
    this._onTurboRender = () => {
      if (!this.element.querySelector("svg")) this._draw();
    };
    document.addEventListener("turbo:render", this._onTurboRender);
    document.addEventListener("turbo:frame-load", this._onTurboRender);
  }

  disconnect() {
    window.removeEventListener("resize", this._resize);
    this._observer?.disconnect();
    this._themeObserver?.disconnect();
    if (this._onTurboRender) {
      document.removeEventListener("turbo:render", this._onTurboRender);
      document.removeEventListener("turbo:frame-load", this._onTurboRender);
    }
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

    // Reserve gutter for y-axis labels when there's room. Mobile (< 320)
    // keeps the tighter left margin and skips the y-axis entirely.
    const yAxisVisible = width - 16 - 24 >= 320;
    const margin = { top: 28, right: 24, bottom: 28, left: yAxisVisible ? 44 : 16 };
    const innerWidth = width - margin.left - margin.right;
    const innerHeight = height - margin.top - margin.bottom;

    // Date-only payload strings ("YYYY-MM-DD") parse as UTC midnight in
    // `new Date(str)`, which shifts displayed days back one for users west
    // of Greenwich. Parse components so today/target/saved_series sit on
    // local-midnight.
    const parseLocalDate = (s) => {
      if (!s) return null;
      const [ y, m, d ] = s.split("-").map(Number);
      return new Date(y, m - 1, d);
    };
    const start = parseLocalDate(data.start_date);
    const today = parseLocalDate(data.today);
    const target = parseLocalDate(data.target_date);
    const targetAmount = data.target_amount || 0;
    const currentAmount = data.current_amount || 0;
    const avgMonthly = data.avg_monthly || 0;

    // Past-due goals: pin endDate at today so the "today" marker stays inside
    // the x-domain instead of clipping right at the edge.
    const endDate = target
      ? new Date(Math.max(target.getTime(), today.getTime()))
      : new Date(today.getTime() + 30 * 24 * 60 * 60 * 1000);

    // Drop any same-day-or-later points from the balance series: we own the
    // endpoint with `currentAmount` (live `linked_accounts.sum(:balance)`)
    // so the saved line meets the projection's starting point with no gap.
    // Without this, the snapshot in `balances` for today could differ from
    // the live read (sync timing) and the chart showed a vertical jump.
    const rawSavedSeries = (data.saved_series || [])
      .map((p) => ({ date: parseLocalDate(p.date), value: p.value }))
      .filter((p) => p.date < today);
    const firstContribDate = rawSavedSeries[0]?.date;
    const savedSeries = [];
    // Only seed a (start, 0) point when start_date predates the first
    // contribution. Otherwise the line draws a vertical jump up at the
    // chart's left edge.
    if (!firstContribDate || firstContribDate.getTime() > start.getTime()) {
      savedSeries.push({ date: start, value: 0 });
    }
    savedSeries.push(...rawSavedSeries);
    // Always close the saved line at (today, currentAmount) — the projection
    // line starts here too, guaranteeing visual continuity at the today
    // marker.
    savedSeries.push({ date: today, value: currentAmount });

    const projectionEnd = target
      ? Math.max(currentAmount, currentAmount + avgMonthly * Math.max(0, this._monthsBetween(today, target)))
      : currentAmount;
    const projectionSeries = target
      ? [
          { date: today, value: currentAmount },
          { date: target, value: projectionEnd },
        ]
      : [];

    const requiredMonthly = data.required_monthly || 0;
    const requiredEnd = target && requiredMonthly > 0
      ? currentAmount + requiredMonthly * Math.max(0, this._monthsBetween(today, target))
      : currentAmount;
    const requiredSeries = target && requiredMonthly > 0 && requiredEnd > currentAmount
      ? [
          { date: today, value: currentAmount },
          { date: target, value: requiredEnd },
        ]
      : [];

    const yMax = Math.max(targetAmount * 1.05, projectionEnd, requiredEnd, currentAmount, 1);

    const x = d3.scaleTime().domain([start, endDate]).range([margin.left, margin.left + innerWidth]);
    const y = d3.scaleLinear().domain([0, yMax]).range([margin.top + innerHeight, margin.top]);

    const svg = d3
      .select(root)
      .append("svg")
      .attr("width", width)
      .attr("height", height)
      .attr("viewBox", `0 0 ${width} ${height}`);

    // Drop the <title> child; browsers render it as a native hover tooltip
    // that fights with our own crosshair tooltip. aria-label gives the same
    // SR accessible name without the tooltip side-effect.
    const descId = `chart-desc-${this._id()}`;
    svg.attr("role", "img").attr("aria-label", this.ariaLabelValue || "Goal projection");
    svg.append("desc").attr("id", descId).text(this.ariaDescriptionValue || "");
    svg.attr("aria-describedby", descId);

    const defs = svg.append("defs");
    const gradient = defs
      .append("linearGradient")
      .attr("id", `saved-fill-${this._id()}`)
      .attr("x1", 0).attr("y1", 0).attr("x2", 0).attr("y2", 1);
    gradient.append("stop").attr("offset", "0%").attr("stop-color", textPrimary).attr("stop-opacity", 0.22);
    gradient.append("stop").attr("offset", "100%").attr("stop-color", textPrimary).attr("stop-opacity", 0);

    const COLLISION_PX = 18;
    const targetY = targetAmount > 0 ? y(targetAmount) : null;
    const yTicks = yAxisVisible ? y.ticks(3) : [];
    const targetCollidesWithTick =
      targetY !== null && yTicks.some((tv) => Math.abs(y(tv) - targetY) < COLLISION_PX);

    if (yAxisVisible) {
      yTicks.forEach((tickValue) => {
        svg
          .append("line")
          .attr("x1", margin.left)
          .attr("x2", margin.left + innerWidth)
          .attr("y1", y(tickValue))
          .attr("y2", y(tickValue))
          .attr("stroke", borderSubdued)
          .attr("stroke-width", 1);
        // Skip the y-axis label when its row is close to the target line.
        // The target's own label will take over that y-slot below.
        if (targetY !== null && Math.abs(y(tickValue) - targetY) < COLLISION_PX) return;
        svg
          .append("text")
          .attr("x", margin.left - 6)
          .attr("y", y(tickValue) + 3)
          .attr("text-anchor", "end")
          .attr("font-size", 12)
          .attr("fill", textSecondary)
          .text(this._fmtMoneyShort(tickValue, data.currency));
      });
    }

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

      if (targetCollidesWithTick) {
        // Merge target label into the y-axis column at the target's y-row.
        // The collided y-axis tick was suppressed above so this label takes
        // over that slot cleanly.
        svg
          .append("text")
          .attr("x", margin.left - 6)
          .attr("y", targetY + 3)
          .attr("text-anchor", "end")
          .attr("font-size", 12)
          .attr("fill", textPrimary)
          .text(`Target · ${data.target_amount_short_label}`);
      } else {
        // Plenty of room: keep the right-side full-format label.
        svg
          .append("text")
          .attr("x", margin.left + innerWidth - 4)
          .attr("y", targetY - 6)
          .attr("text-anchor", "end")
          .attr("font-size", 12)
          .attr("fill", textPrimary)
          .text(`Target · ${data.target_amount_label}`);
      }
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

    if (requiredSeries.length) {
      // Light dashed reference line: the path needed to hit the target.
      // Neutral stroke (text-secondary) instead of green: both the
      // projection and the required line are otherwise green when the
      // goal is on track, and the two would visually merge.
      svg
        .append("path")
        .datum(requiredSeries)
        .attr("fill", "none")
        .attr("stroke", textSecondary)
        .attr("stroke-width", 1.2)
        .attr("stroke-linecap", "round")
        .attr("stroke-dasharray", "2 4")
        .attr("opacity", 0.5)
        .attr("d", line);
    }

    if (projectionSeries.length) {
      const willHit = projectionEnd >= targetAmount;
      const projColor = willHit ? "var(--color-green-600)" : "var(--color-yellow-600)";
      svg
        .append("path")
        .datum(projectionSeries)
        .attr("fill", "none")
        .attr("stroke", projColor)
        .attr("stroke-width", 2)
        .attr("stroke-linecap", "round")
        .attr("stroke-dasharray", "4 4")
        .attr("d", line);

      svg
        .append("circle")
        .attr("cx", x(target))
        .attr("cy", y(projectionEnd))
        .attr("r", 4)
        .attr("fill", projColor)
        .attr("stroke", containerBg)
        .attr("stroke-width", 2);

      // Suppress the projection-end label when it would visually collide
      // with the target label above. In a barely-on-track case the dot
      // already conveys "you'll hit the target". duplicating "$2.4K"
      // beside "Target · $2,400" adds noise.
      const projDotY = y(projectionEnd);
      const collidesWithTargetLabel = targetAmount > 0 && Math.abs(projDotY - y(targetAmount)) < 18;

      if (innerWidth >= 320 && !(willHit && collidesWithTargetLabel)) {
        // Server-rendered labels: projection_end_label is the full-format
        // currency for the on-track endpoint, projection_shortfall_label
        // is the "$X short" string when we fall short.
        const labelText = willHit
          ? data.projection_end_label
          : (data.projection_shortfall_label ? `${data.projection_shortfall_label} short` : "");
        if (labelText) {
          svg
            .append("text")
            .attr("x", x(target) - 8)
            .attr("y", y(projectionEnd) - 8)
            .attr("text-anchor", "end")
            .attr("font-size", 12)
            .attr("fill", textSecondary)
            .attr("paint-order", "stroke")
            .attr("stroke", containerBg)
            .attr("stroke-width", 4)
            .attr("stroke-linejoin", "round")
            .text(labelText);
        }
      }
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

    if (innerWidth >= 320) {
      svg
        .append("text")
        .attr("x", x(today))
        .attr("y", margin.top - 4)
        .attr("text-anchor", "middle")
        .attr("font-size", 12)
        .attr("fill", textSecondary)
        .text(this.todayLabelValue);
    }

    // Full 4-digit year so the terminal "Jan 2027" reads as the year, not
    // as "Jan 27" (which scans as January 27th). Slightly wider per tick;
    // the de-dupe logic below keeps the count sane.
    const tickFmt = d3.timeFormat("%b %Y");
    const tickCount = Math.min(5, Math.max(2, Math.round(innerWidth / 80)));
    const ticks = x.ticks(tickCount);
    const tickGroup = svg.append("g");
    tickGroup
      .selectAll("text")
      .data(ticks)
      .enter()
      .append("text")
      .attr("x", (d) => x(d))
      .attr("y", height - 8)
      .attr("text-anchor", "middle")
      .attr("font-size", 12)
      .attr("fill", textSecondary)
      .text((d) => tickFmt(d));
    // De-dupe adjacent equal tick labels (e.g. multiple "May '26" on a
    // short window where d3.ticks oversamples).
    const tickNodes = tickGroup.selectAll("text").nodes();
    for (let i = tickNodes.length - 1; i > 0; i--) {
      if (tickNodes[i].textContent === tickNodes[i - 1].textContent) {
        tickNodes[i].remove();
      }
    }

    // Hover interactivity: crosshair + dots + tooltip on pointermove.
    // Transparent rect catches pointer events across the plot area.
    const crosshair = svg
      .append("line")
      .attr("y1", margin.top)
      .attr("y2", margin.top + innerHeight)
      .attr("stroke", textSecondary)
      .attr("stroke-width", 1)
      .attr("stroke-dasharray", "2 2")
      .attr("pointer-events", "none")
      .style("display", "none");

    const hoverSavedDot = svg
      .append("circle")
      .attr("r", 4)
      .attr("fill", textPrimary)
      .attr("stroke", containerBg)
      .attr("stroke-width", 2)
      .attr("pointer-events", "none")
      .style("display", "none");

    const hoverProjDot = svg
      .append("circle")
      .attr("r", 4)
      .attr("fill", projectionSeries.length && projectionEnd >= targetAmount ? "var(--color-green-600)" : "var(--color-yellow-600)")
      .attr("stroke", containerBg)
      .attr("stroke-width", 2)
      .attr("pointer-events", "none")
      .style("display", "none");

    // Only promote root to a positioned ancestor when it currently has no
    // positioning context. Inline checks against `root.style.position`
    // miss positions set via CSS (the inline style is empty), so we'd
    // clobber a stylesheet `position: fixed/sticky/absolute` with our
    // own `relative`. Read the computed style instead.
    if (getComputedStyle(root).position === "static") root.style.position = "relative";
    // Shared visual contract (utils/chart_tooltip) — this used to be a
    // hand-copied class string that drifted from the other charts the moment
    // the contract changed.
    const tooltip = createChartTooltip(root);
    // This tooltip snaps between discrete dates (not raw cursor positions),
    // so the glide reads as easing, not lag. Cursor-following tooltips must
    // not do this — see the .chart-tooltip comment in components.css.
    tooltip.style.transition = "left 80ms ease-out, top 80ms ease-out";
    const tooltipDate = document.createElement("div");
    tooltipDate.className = CHART_TOOLTIP_CONTEXT_CLASSES;
    const tooltipValue = document.createElement("div");
    tooltipValue.className = CHART_TOOLTIP_VALUE_CLASSES;
    // Relation line: where this value sits against the goal target. Tertiary
    // so the hierarchy stays date < value > relation; hidden when the goal
    // has no positive target to compare against.
    const tooltipRelation = document.createElement("div");
    tooltipRelation.className = "text-xs text-subdued mt-0.5";
    tooltip.replaceChildren(tooltipDate, tooltipValue, tooltipRelation);

    const setRelation = (amount) => {
      // `targetAmount` is _draw()'s outer const (data.target_amount) — no
      // local copy, which previously shadowed the `target` date const.
      if (targetAmount <= 0 || !data.target_amount_short_label) {
        tooltipRelation.style.display = "none";
        return;
      }
      const percent = Math.round((amount / targetAmount) * 100);
      tooltipRelation.textContent = this.targetRelationTemplateValue
        .replace("{percent}", percent)
        .replace("{target}", data.target_amount_short_label);
      tooltipRelation.style.display = "";
    };

    const overlay = svg
      .append("rect")
      .attr("x", margin.left)
      .attr("y", margin.top)
      .attr("width", innerWidth)
      .attr("height", innerHeight)
      .attr("fill", "transparent")
      .style("cursor", "crosshair");

    const bisectDate = d3.bisector((d) => d.date).left;
    const dateFmt = d3.timeFormat("%b %d, %Y");
    const todayTs = today.getTime();
    const targetTs = target ? target.getTime() : null;
    const MS_PER_WEEK = 7 * 24 * 60 * 60 * 1000;

    const showAt = (xPos, yPos) => {
      const xVal = x.invert(xPos);
      if (!savedSeries.length) return;

      const future = xVal.getTime() > todayTs && projectionSeries.length && targetTs;

      // Date the crosshair + the active dot snaps to. Past = nearest saved
      // contribution (sparse, monthly-ish). Future = weekly steps along the
      // projection segment so the cursor doesn't jitter pixel-by-pixel.
      let hoverDate;
      if (future) {
        const weeks = Math.round((xVal.getTime() - todayTs) / MS_PER_WEEK);
        let snapped = todayTs + weeks * MS_PER_WEEK;
        if (snapped > targetTs) snapped = targetTs;
        if (snapped < todayTs) snapped = todayTs;
        hoverDate = new Date(snapped);
      } else {
        const i = bisectDate(savedSeries, xVal);
        const a = savedSeries[Math.max(0, i - 1)];
        const b = savedSeries[Math.min(savedSeries.length - 1, i)];
        hoverDate = !a ? b.date : !b ? a.date : (xVal - a.date < b.date - xVal ? a.date : b.date);
      }

      const hoverX = x(hoverDate);
      crosshair.attr("x1", hoverX).attr("x2", hoverX).style("display", null);

      tooltipDate.textContent = dateFmt(hoverDate);

      if (future) {
        // Projection segment: interpolate along the dashed line; saved dot
        // stays hidden (no saved value in the future).
        const tFrac = (hoverDate.getTime() - todayTs) / (targetTs - todayTs);
        const projValue = currentAmount + tFrac * (projectionEnd - currentAmount);
        hoverProjDot.attr("cx", hoverX).attr("cy", y(projValue)).style("display", null);
        hoverSavedDot.style("display", "none");
        tooltipValue.textContent = this.projectedTemplateValue.replace("{amount}", this._fmtMoney(projValue, data.currency));
        setRelation(projValue);
      } else {
        // Saved segment: hoverDate is already snapped to nearest savedSeries
        // entry above, so reuse that entry directly instead of running
        // bisectDate a second time.
        const savedPoint = savedSeries.find((p) => p.date.getTime() === hoverDate.getTime()) || savedSeries[savedSeries.length - 1];
        hoverSavedDot.attr("cx", x(savedPoint.date)).attr("cy", y(savedPoint.value)).style("display", null);
        hoverProjDot.style("display", "none");
        tooltipValue.textContent = this.savedTemplateValue.replace("{amount}", this._fmtMoney(savedPoint.value, data.currency));
        setRelation(savedPoint.value);
      }

      tooltip.style.display = "block";
      const tipRect = tooltip.getBoundingClientRect();
      const left = Math.min(width - tipRect.width - 4, Math.max(4, xPos + 12));
      const top = Math.max(4, yPos - tipRect.height - 8);
      tooltip.style.left = `${left}px`;
      tooltip.style.top = `${top}px`;
    };

    const hide = () => {
      crosshair.style("display", "none");
      hoverSavedDot.style("display", "none");
      hoverProjDot.style("display", "none");
      tooltip.style.display = "none";
    };

    overlay.on("pointermove", (event) => {
      const [mx, my] = d3.pointer(event);
      showAt(mx, my);
    });
    overlay.on("pointerleave", hide);
  }

  _monthsBetween(a, b) {
    return (b - a) / (1000 * 60 * 60 * 24 * 30.44);
  }

  _fmtMoney(amount, currency) {
    try {
      return new Intl.NumberFormat(undefined, {
        style: "currency",
        currency: currency || "USD",
        maximumFractionDigits: 0,
      }).format(amount);
    } catch {
      // Same server-shipped symbol path as `_fmtMoneyShort`.
      const symbol = this.dataValue?.currency_symbol || "$";
      return `${symbol}${Math.round(amount).toLocaleString()}`;
    }
  }

  _fmtMoneyShort(amount, _currency) {
    // The server ships `currency_symbol` via projection_payload (resolved
    // through Money.new(0, code).currency.symbol so EUR/GBP/JPY/etc. render
    // with the family-locale-correct glyph). Fall back to "$" if a stale
    // payload reaches us mid-deploy.
    const symbol = this.dataValue?.currency_symbol || "$";
    const abs = Math.abs(amount);
    if (abs >= 1_000_000) {
      return `${symbol}${(amount / 1_000_000).toFixed(1).replace(/\.0$/, "")}M`;
    }
    if (abs >= 1_000) {
      return `${symbol}${(amount / 1_000).toFixed(1).replace(/\.0$/, "")}K`;
    }
    return `${symbol}${Math.round(amount).toLocaleString()}`;
  }

  _id() {
    if (!this._cachedId) {
      this._cachedId = Math.random().toString(36).slice(2, 8);
    }
    return this._cachedId;
  }
}
