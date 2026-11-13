import { Controller } from "@hotwired/stimulus";
import * as d3 from "d3";
import { CHART_TOOLTIP_CLASSES } from "utils/chart_tooltip";

const parseLocalDate = d3.timeParse("%Y-%m-%d");

export default class extends Controller {
  static values = {
    data: Object,
    strokeWidth: { type: Number, default: 2 },
    useLabels: { type: Boolean, default: true },
    useTooltip: { type: Boolean, default: true },
    selectable: { type: Boolean, default: false },
  };

  _d3SvgMemo = null;
  _d3GroupMemo = null;
  _d3Tooltip = null;
  _d3InitialContainerWidth = 0;
  _d3InitialContainerHeight = 0;
  _normalDataPoints = [];
  _resizeObserver = null;
  _d3DragSelectBrush = null;
  _d3DragSelectGroup = null;
  // d3 only nulls a truly zero-width selection, so 1-3px of jitter on a click
  // still arrives here as a real drag. On a dense period (365D is ~2px per
  // point) that is enough to straddle two data points and navigate somewhere
  // the user never aimed at, so treat anything this small as a click.
  _dragSelectMinPx = 4;
  // Touch (see _bindTouchHandlers): how long a finger rests before a slide
  // selects a range instead of moving the tooltip, how far it may drift while
  // resting, and the touch in progress.
  _longPressMs = 450;
  _touchSlopPx = 10;
  _touch = null;
  // performance.now() counts from the page load: 0 would make its first
  // second look like a touch had just happened and ignore the mouse.
  _lastTouchAt = Number.NEGATIVE_INFINITY;
  _touchTooltipShown = false;
  // y-axis domain tuning. Both are relative to the data, so the scale is
  // resolution-independent: a chart looks the same on a phone and a 4K
  // display — only pixel density changes.
  _yAxisPadding = 0.12;      // breathing room above and below the series
  _yAxisMinRelSpan = 0.015;  // smallest movement allowed to fill the chart,
                             // as a fraction of the average balance  

  connect() {
    this._install();
    document.addEventListener("turbo:load", this._reinstall);
    document.addEventListener("pointerdown", this._onDocumentPointerDown, true);
    this._setupResizeObserver();
  }

  disconnect() {
    this._teardown();
    document.removeEventListener("turbo:load", this._reinstall);
    document.removeEventListener(
      "pointerdown",
      this._onDocumentPointerDown,
      true,
    );
    this._resizeObserver?.disconnect();
  }

  _reinstall = () => {
    this._teardown();
    this._install();
  };

  _teardown() {
    this._d3SvgMemo = null;
    this._d3GroupMemo = null;
    this._d3Tooltip = null;
    this._normalDataPoints = [];
    this._d3DragSelectBrush = null;
    this._d3DragSelectGroup = null;
    clearTimeout(this._touch?.timer);
    this._touch = null;
    this._touchTooltipShown = false;

    this._d3Container.selectAll("*").remove();
  }

  _install() {
    this._normalizeDataPoints();
    this._rememberInitialContainerSize();
    this._draw();
  }

  _normalizeDataPoints() {
    this._normalDataPoints = (this.dataValue.values || []).map((d) => ({
      date: parseLocalDate(d.date),
      date_formatted: d.date_formatted,
      value: d.value,
      trend: d.trend,
    }));
  }

  _rememberInitialContainerSize() {
    this._d3InitialContainerWidth = this._d3Container.node().clientWidth;
    this._d3InitialContainerHeight = this._d3Container.node().clientHeight;
  }

  _draw() {
    // Guard against unmeasurable dimensions (e.g., when the container is
    // collapsed or not yet rendered). A hidden container measures 0x0, and the
    // ResizeObserver re-installs the chart as soon as layout gives it a real
    // size, so skipping here only ever defers hidden charts. Small-but-real
    // containers like the 32px-wide sidebar sparklines still render.
    if (this._d3ContainerWidth <= 0 || this._d3ContainerHeight <= 0) {
      return;
    }

    if (this._normalDataPoints.length < 2) {
      this._drawEmpty();
    } else {
      this._drawChart();
    }
  }

  _drawEmpty() {
    this._d3Svg.selectAll(".tick").remove();
    this._d3Svg.selectAll(".domain").remove();

    this._drawDashedLineEmptyState();
    this._drawCenteredCircleEmptyState();
  }

  _drawDashedLineEmptyState() {
    this._d3Svg
      .append("line")
      .attr("x1", this._d3InitialContainerWidth / 2)
      .attr("y1", 0)
      .attr("x2", this._d3InitialContainerWidth / 2)
      .attr("y2", this._d3InitialContainerHeight)
      .attr("stroke", "var(--color-gray-300)")
      .attr("stroke-dasharray", "4, 4");
  }

  _drawCenteredCircleEmptyState() {
    this._d3Svg
      .append("circle")
      .attr("cx", this._d3InitialContainerWidth / 2)
      .attr("cy", this._d3InitialContainerHeight / 2)
      .attr("r", 4)
      .attr("class", "text-subdued")
      .style("fill", "currentColor");
  }

  _drawChart() {
    this._drawTrendline();

    if (this.useLabelsValue) {
      this._drawXAxisLabels();
      this._drawGradientBelowTrendline();
    }

    if (this.useTooltipValue) {
      this._drawTooltip();
    }

    if (this.useTooltipValue || this.selectableValue) {
      this._drawInteractionOverlay();
    }
  }

  _drawTrendline() {
    this._installTrendlineSplit();

    this._d3Group
      .append("path")
      .datum(this._normalDataPoints)
      .attr("fill", "none")
      .attr("stroke", `url(#${this.element.id}-split-gradient)`)
      .attr("d", this._d3Line)
      .attr("stroke-linejoin", "round")
      .attr("stroke-linecap", "round")
      // A flat series (no variation across the period — a single valuation or an
      // unchanged balance) otherwise renders as a full-bleed near-black rule
      // bisecting the hero card. Draw it as a faint hairline so it reads as
      // "no change", consistent across light and dark (#2137).
      .attr("stroke-width", this._isFlatSeries ? 1 : this.strokeWidthValue)
      .attr("stroke-opacity", this._isFlatSeries ? 0.4 : 1);
  }

  get _isFlatSeries() {
    const min = d3.min(this._normalDataPoints, this._getDatumValue);
    const max = d3.max(this._normalDataPoints, this._getDatumValue);
    return min === max;
  }

  _installTrendlineSplit() {
    const gradient = this._d3Svg
      .append("defs")
      .append("linearGradient")
      .attr("id", `${this.element.id}-split-gradient`)
      .attr("gradientUnits", "userSpaceOnUse")
      .attr("x1", this._d3XScale.range()[0])
      .attr("x2", this._d3XScale.range()[1]);

    // First stop - solid trend color
    gradient
      .append("stop")
      .attr("class", "start-color")
      .attr("offset", "0%")
      .attr("stop-color", this.dataValue.trend.color);

    // Second stop - trend color right before split
    gradient
      .append("stop")
      .attr("class", "split-before")
      .attr("offset", "100%")
      .attr("stop-color", this.dataValue.trend.color);

    // Third stop - gray color right after split
    gradient
      .append("stop")
      .attr("class", "split-after")
      .attr("offset", "100%")
      .attr("stop-color", "var(--color-gray-400)");

    // Fourth stop - solid gray to end
    gradient
      .append("stop")
      .attr("class", "end-color")
      .attr("offset", "100%")
      .attr("stop-color", "var(--color-gray-400)");
  }

  _setTrendlineSplitAt(percent) {
    const position = percent * 100;

    // Update both stops at the split point
    this._d3Svg
      .select(`#${this.element.id}-split-gradient`)
      .select(".split-before")
      .attr("offset", `${position}%`);

    this._d3Svg
      .select(`#${this.element.id}-split-gradient`)
      .select(".split-after")
      .attr("offset", `${position}%`);

    this._d3Svg
      .select(`#${this.element.id}-trendline-gradient-rect`)
      .attr("width", this._d3ContainerWidth * percent);
  }

  _drawXAxisLabels() {
    // Add ticks
    this._d3Group
      .append("g")
      .attr("transform", `translate(0,${this._d3ContainerHeight})`)
      .call(
        d3
          .axisBottom(this._d3XScale)
          .tickValues([
            this._normalDataPoints[0].date,
            this._normalDataPoints[this._normalDataPoints.length - 1].date,
          ])
          .tickSize(0)
          .tickFormat(d3.timeFormat("%b %d, %Y")),
      )
      .select(".domain")
      .remove();

    // Style ticks
    this._d3Group
      .selectAll(".tick text")
      .attr("class", "text-secondary")
      .style("font-size", "12px")
      .style("font-weight", "500")
      .attr("text-anchor", "middle")
      .attr("dx", (_d, i) => {
        // We know we only have 2 values
        return i === 0 ? "5em" : "-5em";
      })
      .attr("dy", "0em");
  }

  _drawGradientBelowTrendline() {
    // Define gradient
    const gradient = this._d3Group
      .append("defs")
      .append("linearGradient")
      .attr("id", `${this.element.id}-trendline-gradient`)
      .attr("gradientUnits", "userSpaceOnUse")
      .attr("x1", 0)
      .attr("x2", 0)
      .attr(
        "y1",
        this._d3YScale(d3.max(this._normalDataPoints, this._getDatumValue)),
      )
      .attr("y2", this._d3ContainerHeight);

    gradient
      .append("stop")
      .attr("offset", 0)
      .attr("stop-color", this._trendColor)
      .attr("stop-opacity", 0.06);

    gradient
      .append("stop")
      .attr("offset", 0.5)
      .attr("stop-color", this._trendColor)
      .attr("stop-opacity", 0);

    // Clip path makes gradient start at the trendline
    this._d3Group
      .append("clipPath")
      .attr("id", `${this.element.id}-clip-below-trendline`)
      .append("path")
      .datum(this._normalDataPoints)
      .attr(
        "d",
        d3
          .area()
          .x((d) => this._d3XScale(d.date))
          .y0(this._d3ContainerHeight)
          .y1((d) => this._d3YScale(this._getDatumValue(d))),
      );

    // Apply the gradient + clip path
    this._d3Group
      .append("rect")
      .attr("id", `${this.element.id}-trendline-gradient-rect`)
      .attr("width", this._d3ContainerWidth)
      .attr("height", this._d3ContainerHeight)
      .attr("clip-path", `url(#${this.element.id}-clip-below-trendline)`)
      .style("fill", `url(#${this.element.id}-trendline-gradient)`);
  }

  _drawTooltip() {
    this._d3Tooltip = d3
      .select(`#${this.element.id}`)
      .append("div")
      // Shared visual contract + this chart's initial-hidden / positioning classes.
      .attr("class", `${CHART_TOOLTIP_CLASSES} opacity-0 top-0`);
  }

  // The interaction surface is either a plain full-size rect (hover-only charts)
  // or a d3-brush overlay (selectable charts, which also need drag capture).
  // Either way, tooltip handlers bind to whichever element ends up on top so
  // hover and drag-select never fight over the same pointer events.
  _drawInteractionOverlay() {
    if (this.selectableValue) {
      this._drawDragSelectOverlay();
    } else {
      this._drawHoverOverlay();
    }
  }

  _drawHoverOverlay() {
    const rect = this._d3Group
      .append("rect")
      .attr("class", "bg-container")
      .attr("width", this._d3ContainerWidth)
      .attr("height", this._d3ContainerHeight)
      .attr("fill", "none")
      .attr("pointer-events", "all");

    this._bindTooltipHandlers(rect);
    this._bindTouchHandlers(rect, { selectable: false });
  }

  _drawDragSelectOverlay() {
    const brush = d3
      .brushX()
      .extent([
        [0, 0],
        [this._d3ContainerWidth, this._d3ContainerHeight],
      ])
      // d3-brush treats any touch-capable device as "touchable" by default,
      // which makes it bind touchstart/touchmove and set touch-action: none
      // on the overlay — silently disabling native scroll on these full-width
      // charts. Drag-select is a mouse-only affordance for now, so opt out of
      // touch handling and leave scrolling/panning untouched on mobile.
      .touchable(false)
      // A tap is followed by emulated mouse events; one of those must not
      // start a mouse drag after a touch gesture (handled below) ended.
      .filter(
        (event) => !event.ctrlKey && !event.button && !this._recentTouch(),
      )
      .on("start brush", (event) => this._handleDragSelectMove(event))
      .on("end", (event) => this._handleDragSelectEnd(event));

    const brushGroup = this._d3Group
      .append("g")
      .attr("class", "drag-select-brush")
      .call(brush);

    brushGroup
      .select(".selection")
      .attr("fill", this._trendColor)
      .attr("fill-opacity", 0.12)
      .attr("stroke", this._trendColor)
      .attr("stroke-opacity", 0.5);

    // Idle hovering (before any mousedown) still goes through the overlay's
    // own mousemove — only an in-progress drag needs the brush events above.
    if (this.useTooltipValue) {
      this._bindTooltipHandlers(brushGroup.select(".overlay"));
    }
    this._bindTouchHandlers(brushGroup.select(".overlay"), {
      selectable: true,
    });

    this._d3DragSelectBrush = brush;
    this._d3DragSelectGroup = brushGroup;
  }

  // d3-brush captures mousemove at the window level while dragging, so the
  // overlay's own "mousemove" listener (used for plain hover) never fires
  // mid-drag. Drive the same tooltip off the brush's own events instead,
  // reading the pointer position from its sourceEvent — this is also what
  // keeps the tooltip glued to an exact data point instead of drifting to
  // whatever fraction-of-a-day pixel the mouse happens to be over.
  _handleDragSelectMove(event) {
    const sourceEvent = event.sourceEvent;
    if (!sourceEvent || typeof sourceEvent.pageX !== "number") return;

    const [xPos] = d3.pointer(sourceEvent, this._d3Group.node());
    const datum = this._nearestDataPointForPixel(xPos);

    this._renderTooltipAt(datum, sourceEvent.pageX, sourceEvent.pageY);
  }

  _handleDragSelectEnd(event) {
    this._hideTooltip();

    if (!event.selection) return;

    const [x0, x1] = event.selection;

    if (!this._selectPixelRange(x0, x1)) {
      this._d3DragSelectGroup?.call(this._d3DragSelectBrush.move, null);
    }
  }

  // Opens the dates between two pixels (x0 <= x1), from a mouse drag or a
  // touch selection. False when the range is too small to be one: the caller
  // clears its selection instead.
  _selectPixelRange(x0, x1) {
    if (x1 - x0 < this._dragSelectMinPx) return false;

    // Snap to the actual plotted data points (same as the tooltip shown
    // during the drag) rather than the raw continuous pixel-to-time value —
    // a few pixels of mouse imprecision can otherwise land on a date that's
    // days away from the one the user was looking at on a wide chart.
    const startDatum = this._nearestDataPointForPixel(x0);
    const endDatum = this._nearestDataPointForPixel(x1);

    // Reject *after* snapping, which is where the outcome is actually decided:
    // a 30D chart is ~27px per point, so a drag can clear the pixel floor above
    // and still collapse to a single date. That range renders one value, which
    // sends _draw() down the empty-state path — and the empty state has no
    // brush left to drag back out of.
    if (startDatum === endDatum) return false;

    this._navigateToDateRange(startDatum.date, endDatum.date);
    return true;
  }

  // Touch. A finger sliding along the chart moves the tooltip with it
  // (scrubbing), and on a selectable chart a finger that rests for a moment
  // and then slides selects a range, as a mouse drag does. The overlay claims
  // only horizontal movement (touch-action: pan-y pinch-zoom), so a vertical
  // swipe still scrolls the page and a pinch still zooms: the browser takes
  // that gesture over and cancels the pointer. Without this a tap only showed
  // the tooltip where it landed.
  _bindTouchHandlers(selection, { selectable }) {
    const node = selection.node();
    // On the <svg>: browsers ignore touch-action on the shapes inside one.
    // Pinch zoom stays the browser's, as everywhere else on the page.
    const svg = this._d3Svg.node();
    svg.style.touchAction = "pan-y pinch-zoom";
    svg.style.webkitUserSelect = "none";
    svg.style.userSelect = "none";
    svg.style.webkitTouchCallout = "none";

    selection
      .on("pointerdown.touch", (event) => this._touchStart(event, selectable))
      .on("pointermove.touch", (event) => this._touchMove(event))
      .on("pointerup.touch", (event) => this._touchEnd(event))
      .on("pointercancel.touch", (event) => this._touchCancel(event))
      // A long press otherwise opens the browser's context menu.
      .on("contextmenu.touch", (event) => {
        if (this._touch || this._recentTouch()) event.preventDefault();
      });
    // Once a selection has started, the finger may drift up or down while it
    // slides; only a cancelable touchmove can keep that from scrolling.
    node.addEventListener("touchmove", this._preventScrollWhileSelecting, {
      passive: false,
    });
    // A card holding the chart may be reordered by holding it (the dashboard,
    // after 800 ms): on the chart a hold selects a range instead, as a mouse
    // drag on it does (the chart is draggable="false" there).
    // On the whole <svg>, so its margins and axis labels count too.
    svg.addEventListener("touchstart", this._keepTouchInChart, {
      passive: true,
    });
  }

  _touchStart(event, selectable) {
    // Only a gesture's first finger: a second one is a pinch, which
    // _onDocumentPointerDown handles wherever it lands. A new first finger
    // means any earlier touch has ended, even one whose end this chart missed
    // (redrawn while the finger was down), so it starts afresh.
    if (event.pointerType !== "touch" || !event.isPrimary) return;
    if (this._touch) this._abortTouch();

    this._lastTouchAt = performance.now();
    const x = this._touchX(event);
    this._touch = {
      id: event.pointerId,
      startClientX: event.clientX,
      startClientY: event.clientY,
      x,
      anchorX: x,
      selecting: false,
      timer: selectable
        ? setTimeout(() => this._startTouchSelection(), this._longPressMs)
        : null,
    };
    this._scrubTo(event);
  }

  _touchMove(event) {
    const touch = this._touch;
    if (!touch || event.pointerId !== touch.id) return;

    this._lastTouchAt = performance.now();
    if (
      touch.timer &&
      Math.hypot(
        event.clientX - touch.startClientX,
        event.clientY - touch.startClientY,
      ) > this._touchSlopPx
    ) {
      clearTimeout(touch.timer);
      touch.timer = null;
    }

    touch.x = this._touchX(event);
    if (touch.selecting) this._drawTouchSelection(touch.anchorX, touch.x);
    this._scrubTo(event);
  }

  // A tap or a slide leaves the tooltip on the last point (touching anywhere
  // else hides it); a selection opens its range.
  _touchEnd(event) {
    const touch = this._touch;
    if (!touch || event.pointerId !== touch.id) return;

    this._lastTouchAt = performance.now();
    clearTimeout(touch.timer);
    this._touch = null;

    if (touch.selecting) {
      this._removeTouchSelection();
      // A long press lifted without sliding, or with no more than a finger's
      // drift (on a dense period a few pixels reach the next day), selects
      // nothing and keeps the tooltip, as a tap does.
      const slid = Math.abs(touch.x - touch.anchorX) >= this._touchSlopPx;
      const opened =
        slid &&
        this._selectPixelRange(
          Math.min(touch.anchorX, touch.x),
          Math.max(touch.anchorX, touch.x),
        );
      if (opened) this._hideTooltip();
    }
  }

  // The browser took the gesture over: a vertical swipe scrolls the page, so
  // the tooltip goes. A selection the browser ends (some end a long press
  // this way rather than with pointerup) opens nothing and keeps the tooltip.
  _touchCancel(event) {
    const touch = this._touch;
    if (!touch || event.pointerId !== touch.id) return;

    clearTimeout(touch.timer);
    this._touch = null;
    this._removeTouchSelection();
    if (!touch.selecting) this._hideTooltip();
  }

  _abortTouch() {
    clearTimeout(this._touch?.timer);
    this._touch = null;
    this._removeTouchSelection();
    this._hideTooltip();
  }

  _startTouchSelection() {
    const touch = this._touch;
    if (!touch) return;

    touch.timer = null;
    touch.selecting = true;
    touch.anchorX = touch.x;
    navigator.vibrate?.(10);
    this._drawTouchSelection(touch.anchorX, touch.x);
  }

  _keepTouchInChart = (event) => {
    event.stopPropagation();
  };

  // One finger only: a second one makes it a pinch, which stays the browser's.
  _preventScrollWhileSelecting = (event) => {
    if (
      this._touch?.selecting &&
      event.cancelable &&
      event.touches.length === 1
    )
      event.preventDefault();
  };

  // On the document (capture), so a touch counts wherever it lands. A second
  // finger starts a pinch: the long press or the selection is dropped rather
  // than let lifting the first finger open a range, also when it lands on the
  // chart's margin or off the chart. A touch elsewhere hides the tooltip.
  _onDocumentPointerDown = (event) => {
    if (event.pointerType !== "touch") return;
    if (!event.isPrimary) {
      if (this._touch) this._abortTouch();
      return;
    }
    if (this._touchTooltipShown && !this.element.contains(event.target)) {
      this._hideTooltip();
    }
  };

  // Emulated mouse events follow a tap; they must not act as a mouse would.
  _recentTouch() {
    return performance.now() - this._lastTouchAt < 1000;
  }

  _touchX(event) {
    const [xPos] = d3.pointer(event, this._d3Group.node());
    return Math.max(0, Math.min(xPos, this._d3ContainerWidth));
  }

  _scrubTo(event) {
    const datum = this._nearestDataPointForPixel(this._touchX(event));
    this._renderTooltipAt(datum, event.pageX, event.pageY, { touch: true });
    this._touchTooltipShown = true;
  }

  _drawTouchSelection(x0, x1) {
    let rect = this._d3Group.select(".touch-selection");
    if (rect.empty()) {
      rect = this._d3Group
        .append("rect")
        .attr("class", "touch-selection")
        .attr("y", 0)
        .attr("height", this._d3ContainerHeight)
        .attr("fill", this._trendColor)
        .attr("fill-opacity", 0.12)
        .attr("stroke", this._trendColor)
        .attr("stroke-opacity", 0.5)
        .attr("pointer-events", "none");
    }
    rect
      .attr("x", Math.min(x0, x1))
      .attr("width", Math.max(1, Math.abs(x1 - x0)));
  }

  _removeTouchSelection() {
    this._d3Group.selectAll(".touch-selection").remove();
  }

  _navigateToDateRange(startDate, endDate) {
    const formatDate = d3.timeFormat("%Y-%m-%d");
    const url = new URL(window.location.href);

    url.searchParams.delete("period");
    url.searchParams.set("start_date", formatDate(startDate));
    url.searchParams.set("end_date", formatDate(endDate));

    Turbo.visit(url.toString());
  }

  _nearestDataPointForPixel(xPos) {
    const bisectDate = d3.bisector((d) => d.date).left;
    const clampedX = Math.max(0, Math.min(xPos, this._d3ContainerWidth));
    const x0 = bisectDate(
      this._normalDataPoints,
      this._d3XScale.invert(clampedX),
      1,
    );
    const d0 = this._normalDataPoints[Math.max(x0 - 1, 0)];
    const d1 =
      this._normalDataPoints[Math.min(x0, this._normalDataPoints.length - 1)];

    return clampedX - this._d3XScale(d0.date) >
      this._d3XScale(d1.date) - clampedX
      ? d1
      : d0;
  }

  _bindTooltipHandlers(selection) {
    selection
      .on("mousemove", (event) => {
        if (this._recentTouch()) return;
        const [xPos] = d3.pointer(event);
        const datum = this._nearestDataPointForPixel(xPos);

        this._renderTooltipAt(datum, event.pageX, event.pageY);
      })
      .on("mouseout", (event) => {
        if (this._recentTouch()) return;
        const hoveringOnGuideline =
          event.toElement?.classList.contains("guideline");

        if (!hoveringOnGuideline) {
          this._hideTooltip();
        }
      });
  }

  _renderTooltipAt(datum, pageX, pageY, { touch = false } = {}) {
    const estimatedTooltipWidth = 250;
    const pageWidth = document.body.clientWidth;
    const tooltipX = pageX + 10;
    const overflowX = tooltipX + estimatedTooltipWidth - pageWidth;
    const adjustedX = overflowX > 0 ? pageX - overflowX - 20 : tooltipX;

    const xPercent = this._d3XScale(datum.date) / this._d3ContainerWidth;

    this._setTrendlineSplitAt(xPercent);

    // Reset
    this._d3Group.selectAll(".data-point-circle").remove();
    this._d3Group.selectAll(".guideline").remove();

    // Guideline
    this._d3Group
      .append("line")
      .attr("class", "guideline text-subdued")
      .attr("x1", this._d3XScale(datum.date))
      .attr("y1", 0)
      .attr("x2", this._d3XScale(datum.date))
      .attr("y2", this._d3ContainerHeight)
      .attr("stroke", "currentColor")
      .attr("stroke-dasharray", "4, 4")
      // A touch on the line (the tooltip stays after a tap) must reach the
      // overlay underneath, as with the point circles.
      .attr("pointer-events", "none");

    // Big circle
    this._d3Group
      .append("circle")
      .attr("class", "data-point-circle")
      .attr("cx", this._d3XScale(datum.date))
      .attr("cy", this._d3YScale(this._getDatumValue(datum)))
      .attr("r", 10)
      .attr("fill", this._trendColor)
      .attr("fill-opacity", "0.1")
      .attr("pointer-events", "none");

    // Small circle
    this._d3Group
      .append("circle")
      .attr("class", "data-point-circle")
      .attr("cx", this._d3XScale(datum.date))
      .attr("cy", this._d3YScale(this._getDatumValue(datum)))
      .attr("r", 5)
      .attr("fill", this._trendColor)
      .attr("pointer-events", "none");

    // Render tooltip. Optional, to match _hideTooltip: the brush drives this
    // method unconditionally, so a selectable chart with use_tooltip=false has
    // no tooltip node — but it still gets the guideline and circles above.
    this._d3Tooltip
      ?.html(this._tooltipTemplate(datum))
      .style("opacity", 1)
      .style("z-index", 999)
      .style("left", `${adjustedX}px`)
      .style("top", `${pageY - 10}px`);

    if (touch) this._placeTooltipAboveFinger(pageX, pageY);
  }

  // Beside the pointer, a finger would cover the tooltip: above it instead,
  // centred and kept on the page, or below when there is no room above.
  _placeTooltipAboveFinger(pageX, pageY) {
    const node = this._d3Tooltip?.node();
    if (!node) return;

    const gap = 28;
    const width = node.offsetWidth;
    const height = node.offsetHeight;
    const minX = window.scrollX + 8;
    const maxX = window.scrollX + document.body.clientWidth - width - 8;
    const left = Math.max(minX, Math.min(pageX - width / 2, maxX));
    const above = pageY - height - gap;
    const top = above >= window.scrollY + 8 ? above : pageY + gap;

    this._d3Tooltip.style("left", `${left}px`).style("top", `${top}px`);
  }

  _hideTooltip() {
    this._touchTooltipShown = false;
    this._d3Group.selectAll(".guideline").remove();
    this._d3Group.selectAll(".data-point-circle").remove();
    this._d3Tooltip?.style("opacity", 0);
    this._setTrendlineSplitAt(1);
  }

  _tooltipTemplate(datum) {
    return `
      <div class="text-xs text-secondary mb-1">
        ${datum.date_formatted}
      </div>
      <div class="flex items-center gap-4">
        <div class="flex items-center gap-2 text-primary font-medium tabular-nums">
          <div class="flex items-center justify-center h-4 w-4">
            ${this._getTrendIcon(datum)}
          </div>
          ${this._extractFormattedValue(datum.trend.current)}
        </div>

        ${
          this._extractNumericValue(datum.trend.value) === 0
            ? `<span class="w-20"></span>`
            : `
          <span class="tabular-nums" style="color: ${datum.trend.color};">
            ${this._extractFormattedValue(datum.trend.value)}${
              datum.trend.percent === null
                ? ""
                : ` (${datum.trend.percent_formatted})`
            }
          </span>
        `
        }
      </div>
    `;
  }

  _getTrendIcon(datum) {
    const isIncrease =
      Number(datum.trend.previous.amount) < Number(datum.trend.current.amount);
    const isDecrease =
      Number(datum.trend.previous.amount) > Number(datum.trend.current.amount);

    if (isIncrease) {
      return `<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="${datum.trend.color}" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" class="lucide lucide-arrow-up-right-icon lucide-arrow-up-right"><path d="M7 7h10v10"/><path d="M7 17 17 7"/></svg>`;
    }

    if (isDecrease) {
      return `<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="${datum.trend.color}" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" class="lucide lucide-arrow-down-right-icon lucide-arrow-down-right"><path d="m7 7 10 10"/><path d="M17 7v10H7"/></svg>`;
    }

    return `<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="${datum.trend.color}" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" class="lucide lucide-minus-icon lucide-minus"><path d="M5 12h14"/></svg>`;
  }

  _getDatumValue = (datum) => {
    return this._extractNumericValue(datum.value);
  };

  _extractNumericValue = (numeric) => {
    if (typeof numeric === "object" && "amount" in numeric) {
      return Number(numeric.amount);
    }
    return Number(numeric);
  };

  _extractFormattedValue = (numeric) => {
    if (typeof numeric === "object" && "formatted" in numeric) {
      return numeric.formatted;
    }
    return numeric;
  };

  _createMainSvg() {
    return this._d3Container
      .append("svg")
      .attr("width", this._d3InitialContainerWidth)
      .attr("height", this._d3InitialContainerHeight)
      .attr("viewBox", [
        0,
        0,
        this._d3InitialContainerWidth,
        this._d3InitialContainerHeight,
      ]);
  }

  _createMainGroup() {
    return this._d3Svg
      .append("g")
      .attr("transform", `translate(${this._margin.left},${this._margin.top})`);
  }

  get _d3Svg() {
    if (!this._d3SvgMemo) {
      this._d3SvgMemo = this._createMainSvg();
    }
    return this._d3SvgMemo;
  }

  get _d3Group() {
    if (!this._d3GroupMemo) {
      this._d3GroupMemo = this._createMainGroup();
    }
    return this._d3GroupMemo;
  }

  get _margin() {
    if (this.useLabelsValue) {
      return { top: 20, right: 0, bottom: 10, left: 0 };
    }
    return { top: 0, right: 0, bottom: 0, left: 0 };
  }

  get _d3ContainerWidth() {
    return (
      this._d3InitialContainerWidth - this._margin.left - this._margin.right
    );
  }

  get _d3ContainerHeight() {
    return (
      this._d3InitialContainerHeight - this._margin.top - this._margin.bottom
    );
  }

  get _d3Container() {
    return d3.select(this.element);
  }

  get _trendColor() {
    return this.dataValue.trend.color;
  }

  get _d3Line() {
    return d3
      .line()
      .x((d) => this._d3XScale(d.date))
      .y((d) => this._d3YScale(this._getDatumValue(d)));
  }

  get _d3XScale() {
    return d3
      .scaleTime()
      .rangeRound([0, this._d3ContainerWidth])
      .domain(d3.extent(this._normalDataPoints, (d) => d.date));
  }

  get _d3YScale() {
    const dataMin = d3.min(this._normalDataPoints, this._getDatumValue);
    const dataMax = d3.max(this._normalDataPoints, this._getDatumValue);

    // All values identical: fall back to a fixed pad so the line sits centered.
    if (dataMin === dataMax) {
      const padding = dataMax === 0 ? 100 : Math.abs(dataMax) * 0.5;
      return d3
        .scaleLinear()
        .rangeRound([this._d3ContainerHeight, 0])
        .domain([dataMin - padding, dataMax + padding]);
    }

    const dataRange = dataMax - dataMin;
    const avgValue = (dataMax + dataMin) / 2;

    // Honesty floor: never let a movement smaller than _yAxisMinRelSpan of the
    // average balance fill the chart. Trivial noise on a large balance stays
    // visually flat; anything larger is shown at full amplitude. This replaces
    // the previous "2x range below min / 0.5x above" padding, which squashed
    // every small-but-real movement into a near-flat line regardless of size.
    const minSpan = Math.abs(avgValue) * this._yAxisMinRelSpan;
    const effectiveRange = Math.max(dataRange, minSpan);

    const padding = effectiveRange * this._yAxisPadding;
    let yMin = avgValue - effectiveRange / 2 - padding;
    let yMax = avgValue + effectiveRange / 2 + padding;

    // Pull the nearer bound to zero only when the data sits close to zero
    // relative to its own scale (within 10% of the average), so a balance far
    // from zero — positive or negative — still fills the chart with its movement.
    if (dataMin >= 0 && dataMin < avgValue * 0.1) {
      yMin = Math.min(0, yMin);
    } else if (dataMax <= 0 && dataMax > avgValue * 0.1) {
      yMax = Math.max(0, yMax);
    }

    // Extra headroom when value labels are drawn above/below the line.
    if (this.useLabelsValue) {
      const extraPadding = (yMax - yMin) * 0.1;
      yMin -= extraPadding;
      yMax += extraPadding;
    }

    return d3
      .scaleLinear()
      .rangeRound([this._d3ContainerHeight, 0])
      .domain([yMin, yMax]);
  }

  _setupResizeObserver() {
    this._resizeObserver = new ResizeObserver(() => {
      this._reinstall();
    });
    this._resizeObserver.observe(this.element);
  }
}
