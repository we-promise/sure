// Redraws a chart once its container has settled on a new size, stretching
// the drawing it already has in the meantime.
//
// A container resized by an animation (a sidebar opening or closing) or by a
// drag changes size on every frame, and a full d3 redraw on each of them makes
// the animation stutter. Instead the existing SVG is stretched to the new size
// at once, and `redraw` runs when a width transition around the chart ends or
// the size has not changed for `settleMs`. A size that did not change (the
// observer's first callback right after the chart drew) redraws nothing.
//
// Only a width is stretched. A height change (a dashboard height preset, a
// dialog sized to the window) redraws at once: charts have fixed vertical
// margins and data-sized strokes (a Sankey's flows) that a vertical stretch
// would distort, and the animations this is for only change widths.
//
// A chart whose layout changes with its size (the Sankey drops a column below
// a width) passes `layoutChanges(from, to)`: a resize across such a change
// redraws at once rather than stretch a drawing with the wrong columns, so a
// column appears or goes as the width passes the threshold, not at the end.
//
// A shape marked `data-settled-resize-keep-width` (a Sankey's bars) keeps its
// width the same way; a label beside one stays beside it, and a shape marked
// `data-settled-resize-joins` (a Sankey's links) stays joined to the kept
// shapes at its ends. Circles (dots) stay round and lines keep their stroke
// width.
//
// A chart with fixed margins (a Sankey's 16px extent, an axis column) passes
// `margins: { left, right }`: only the part between them is stretched, so
// what sits at the edges stays at its distance from them rather than drift
// with the stretch and jump back at the end.
//
// Text is not stretched with the drawing: each label is scaled back to its
// normal shape around its anchor, and a label marked
// `data-settled-resize-edge="left"` or `"right"` also keeps its distance from
// that edge, so the redraw at the end finds it where it already is.
// Transitions that change an element's width: a sidebar animates its width
// when it opens or closes, and its max-width when resized from the keyboard
// or reset to its default.
const LAYOUT_PROPERTIES = new Set(["width", "max-width", "min-width", "flex-basis"]);

// How far from a kept-width shape a label still counts as beside it.
const BESIDE = 12;

export default class SettledResize {
  constructor(
    element,
    redraw,
    {
      settleMs = 150,
      layoutChanges = () => false,
      margins = { left: 0, right: 0 },
    } = {},
  ) {
    this.element = element;
    this.redraw = redraw;
    this.settleMs = settleMs;
    this.layoutChanges = layoutChanges;
    this.margins = margins;
    this.timer = null;
    this.drawnSize = null;
    // Width transitions running around the chart (a sidebar animating): while
    // any is, only its end settles the chart, not a pause in resizes.
    this.transitions = new Set();
  }

  start() {
    this.drawnSize = this.#size();
    this.observer = new ResizeObserver(() => this.#onResize());
    this.observer.observe(this.element);
    document.addEventListener("transitionrun", this.#onTransitionRun);
    document.addEventListener("transitionend", this.#onTransitionEnd);
    document.addEventListener("transitioncancel", this.#onTransitionEnd);
  }

  stop() {
    this.observer?.disconnect();
    document.removeEventListener("transitionrun", this.#onTransitionRun);
    document.removeEventListener("transitionend", this.#onTransitionEnd);
    document.removeEventListener("transitioncancel", this.#onTransitionEnd);
    clearTimeout(this.timer);
    this.timer = null;
    this.transitions.clear();
  }

  // The chart drew (for any reason): this is now the size it is drawn at.
  drew() {
    this.drawnSize = this.#size();
    this.textGeometry = null;
    // A pending settle would only draw the same size again.
    clearTimeout(this.timer);
    this.timer = null;
  }

  #size() {
    return { width: this.element.clientWidth, height: this.element.clientHeight };
  }

  #onResize() {
    const size = this.#size();
    const drawn = this.drawnSize;
    if (drawn && size.width === drawn.width && size.height === drawn.height) {
      // Back at the drawn size before settling (a quick drag back and forth):
      // the drawing may still be stretched to the last size, so undo that.
      const stretched = this.element.querySelector("svg");
      if (this.timer && stretched) {
        // Resets the labels' counter-scaling; the drawing is at its own
        // size again, so it isn't stretched either.
        this.#stretch(stretched, size);
        stretched.removeAttribute("preserveAspectRatio");
      }
      clearTimeout(this.timer);
      this.timer = null;
      return;
    }

    const svg = this.element.querySelector("svg");
    // Nothing to stretch (a chart that was hidden or too small to draw), a
    // new height, or a size the chart lays out differently: draw now.
    if (
      !svg ||
      !drawn ||
      drawn.width <= 0 ||
      drawn.height <= 0 ||
      size.height !== drawn.height ||
      this.layoutChanges(drawn, size)
    ) {
      this.#settle();
      return;
    }

    this.#stretch(svg, size);
    clearTimeout(this.timer);
    // During a width transition, wait for its end (with a long fallback in case
    // it never comes); otherwise for a pause in resizes (a drag, a window).
    // A transition whose element left the page (a Turbo morph replaced a
    // sidebar mid-animation) never reports its end here: it no longer counts.
    for (const target of this.transitions) {
      if (!target.isConnected) this.transitions.delete(target);
    }
    const wait = this.transitions.size > 0 ? 1000 : this.settleMs;
    this.timer = setTimeout(() => this.#settle(), wait);
  }

  #stretch(svg, size) {
    // Measure the labels once, as drawn, before anything is stretched; again
    // if the SVG was replaced since (a chart's delayed, animated draw).
    if (!this.textGeometry || this.textGeometrySvg !== svg) {
      this.keptGeometry = this.#measureShapes(svg, "[data-settled-resize-keep-width]").map((shape) => ({
        ...shape,
        share: this.#keptWidthShare(shape),
      }));
      this.joinGeometry = this.#measureShapes(svg, "[data-settled-resize-joins]");
      this.textGeometry = this.#measureTexts(svg);
      this.textGeometrySvg = svg;
    }
    const drawn = this.drawnSize;
    const { sx, offset } = this.#horizontalMap(size);
    // x maps to sx * x + offset: the margins keep their width, the part
    // between them stretches by sx.
    svg.setAttribute("viewBox", `${-offset / sx} 0 ${size.width / sx} ${drawn.height}`);
    svg.setAttribute("width", size.width);
    svg.setAttribute("preserveAspectRatio", "none");
    this.textGeometry.forEach((geometry) => this.#keepTextShape(geometry, sx, size));
    // Shapes whose width is part of the design (a Sankey's bars) keep it too,
    // dots stay round, and lines keep their stroke width, so nothing thickens,
    // thins or turns oval with the stretch and snaps back at the end.
    this.keptGeometry.forEach(({ element, share }) => {
      element.style.transformBox = "fill-box";
      element.style.transformOrigin = `${share * 100}% 50%`;
      element.style.transform = `scale(${1 / sx}, 1)`;
    });
    this.joinGeometry.forEach((join) => this.#keepJoined(join, sx, offset));
    svg.querySelectorAll("circle").forEach((dot) => {
      dot.style.transformBox = "fill-box";
      dot.style.transformOrigin = "50% 50%";
      dot.style.transform = `scale(${1 / sx}, 1)`;
    });
    svg.querySelectorAll("path, line, polyline").forEach((line) => {
      line.style.vectorEffect = "non-scaling-stroke";
    });
  }

  // The horizontal stretch: a factor for the part between the margins, and the
  // shift that keeps the left margin's width (sx * x + offset).
  // Where across its width a kept-width shape is held: its share of the way
  // from the left margin to the right one (0 at the left margin, 1 at the
  // right). A bar at the edge keeps its distance from it, and every bar sits
  // where a drawing at this width would put it (a Sankey spaces its columns
  // evenly between the margins). Measured once per drawing.
  #keptWidthShare({ x, width }) {
    const left = Math.min(this.margins.left || 0, this.drawnSize.width / 4);
    const right = Math.min(this.margins.right || 0, this.drawnSize.width / 4);
    const room = this.drawnSize.width - left - right - width;
    return room > 0 ? Math.min(Math.max((x - left) / room, 0), 1) : 0.5;
  }

  // Where a kept-width shape's left edge is shown, in pixels from the chart's
  // left: its anchor point stretches, and the shape keeps its width around it.
  #keptLeft({ x, width, share }, sx, offset) {
    return offset + sx * x + (sx - 1) * share * width;
  }

  // Shapes' boxes in the chart's own coordinates (their groups' offsets
  // included), and the offset of their own coordinates.
  #measureShapes(svg, selector) {
    const toSvg = svg.getScreenCTM()?.inverse();
    return Array.from(svg.querySelectorAll(selector)).flatMap((element) => {
      const ctm = element.getScreenCTM();
      if (!toSvg || !ctm) return [];
      const local = toSvg.multiply(ctm);
      const box = element.getBBox();
      return [{ element, originX: local.e, x: local.e + box.x, width: box.width, y: local.f + box.y, height: box.height }];
    });
  }

  // A shape joining two kept-width shapes (a link from a bar's right edge to
  // another's left edge) is mapped so its ends stay on theirs; an end that
  // joins none just stretches.
  #keepJoined({ element, originX, x, width }, sx, offset) {
    if (width <= 0) return;
    const near = (a, b) => Math.abs(a - b) < 0.5;
    const from = this.keptGeometry.find((kept) => near(kept.x + kept.width, x));
    const to = this.keptGeometry.find((kept) => near(kept.x, x + width));
    const start = from ? this.#keptLeft(from, sx, offset) + from.width : offset + sx * x;
    const end = to ? this.#keptLeft(to, sx, offset) : offset + sx * (x + width);
    // In the chart's coordinates, before the stretch maps them to pixels.
    const startX = (start - offset) / sx;
    const scale = ((end - offset) / sx - startX) / width;
    const shift = startX - scale * x - originX * (1 - scale);
    element.style.transformBox = "view-box";
    element.style.transformOrigin = "0 0";
    element.style.transform = `matrix(${scale}, 0, 0, 1, ${shift}, 0)`;
  }

  #horizontalMap(size) {
    const drawn = this.drawnSize;
    const left = Math.min(this.margins.left || 0, drawn.width / 4);
    const right = Math.min(this.margins.right || 0, drawn.width / 4);
    const inner = drawn.width - left - right;
    const sx = inner > 0 ? Math.max(size.width - left - right, 1) / inner : size.width / drawn.width;
    return { sx, offset: inner > 0 ? left * (1 - sx) : 0 };
  }

  // Where each label's anchor sits, in the chart's own coordinates (its
  // groups' offsets included), and which share of its box that anchor is at.
  #measureTexts(svg) {
    const toSvg = svg.getScreenCTM()?.inverse();
    return Array.from(svg.querySelectorAll("text")).flatMap((text) => {
      const box = text.getBBox();
      const ctm = text.getScreenCTM();
      if (!toSvg || !ctm || box.width === 0) return [];
      const anchor = getComputedStyle(text).textAnchor;
      const share = anchor === "start" ? 0 : anchor === "end" ? 1 : 0.5;
      const local = toSvg.multiply(ctm);
      const x = local.e + box.x + box.width * share;
      // A label just beside a kept-width shape (a Sankey bar's name and value)
      // stays beside it. Any shape in that column will do: they all move
      // alike.
      const beside = this.keptGeometry.find(
        (kept) => x >= kept.x - BESIDE && x <= kept.x + kept.width + BESIDE,
      );
      return [{ text, share, x, edge: text.dataset.settledResizeEdge, beside }];
    });
  }

  // Scales a label back by the stretch, around the point its text-anchor puts
  // it at, so its glyphs keep their shape; an edge label is moved to keep its
  // distance from that edge.
  #keepTextShape({ text, share, x, edge, beside }, sx, size) {
    const { offset } = this.#horizontalMap(size);
    const at = sx * x + offset;
    let dx = 0;
    if (edge === "left") dx = (x - at) / sx;
    if (edge === "right") dx = (size.width - (this.drawnSize.width - x) - at) / sx;
    if (beside) dx = (this.#keptLeft(beside, sx, offset) + (x - beside.x) - at) / sx;
    text.style.transformBox = "fill-box";
    text.style.transformOrigin = `${share * 100}% 50%`;
    text.style.transform = `translate(${dx}px, 0) scale(${1 / sx}, 1)`;
  }

  #settle() {
    clearTimeout(this.timer);
    this.timer = null;
    this.redraw();
    this.drawnSize = this.#size();
    this.textGeometry = null;
  }

  // A width transition that can resize the chart: on one of its ancestors, or
  // on an element in the layout beside one (a sidebar next to the chart's
  // column). One elsewhere on the page (another card's progress bar) or out of
  // the layout (a fixed toast, an absolutely placed popover) can't, and must
  // not hold back or hurry the chart's redraw.
  #isLayoutTransition(event) {
    const target = event.target;
    if (!LAYOUT_PROPERTIES.has(event.propertyName) || !(target instanceof Element)) return false;
    if (this.element.contains(target)) return false;
    if (target.contains(this.element)) return true;
    if (!target.parentElement?.contains(this.element)) return false;
    const position = getComputedStyle(target).position;
    return position !== "fixed" && position !== "absolute";
  }

  #onTransitionRun = (event) => {
    if (this.#isLayoutTransition(event)) this.transitions.add(event.target);
  };

  // A layout transition (a sidebar's width) has ended: redraw at once rather
  // than wait out the settle delay, once no other one is still running.
  #onTransitionEnd = (event) => {
    if (!this.#isLayoutTransition(event)) return;
    this.transitions.delete(event.target);
    if (this.timer && this.transitions.size === 0) this.#settle();
  };
}
