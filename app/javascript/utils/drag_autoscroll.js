// Scrolls the box a dragged item is in while the pointer rests near its top
// or bottom edge, so an item can be moved past what is on screen. Without it
// a held item could only reach the rows already in view: a mouse wheel does
// nothing during a native drag in most browsers, and a touch drag holds the
// page still.
//
// update() is called with the pointer on every move (dragover, touchmove);
// the scrolling runs once per frame, so it carries on while the pointer is
// still, faster the closer it is to the edge. onScroll(x, y) lets the caller
// place the drop position again as the rows move under a still pointer.
export default class DragAutoscroll {
  constructor({ edge = 80, maxStep = 20, onScroll = () => {} } = {}) {
    this.edge = edge;
    this.maxStep = maxStep;
    this.onScroll = onScroll;
    this.scroller = null;
    this.point = null;
    this.frame = null;
  }

  update(element, clientX, clientY) {
    this.scroller ??= scrollParent(element);
    this.point = { x: clientX, y: clientY };
    this.frame ??= requestAnimationFrame(this.#step);
  }

  stop() {
    if (this.frame) cancelAnimationFrame(this.frame);
    this.frame = null;
    this.scroller = null;
    this.point = null;
  }

  #step = () => {
    this.frame = null;
    if (!this.scroller || !this.point) return;

    const step = this.#stepFor(this.point.x, this.point.y);
    if (step === 0) return;

    const before = this.scroller.scrollTop;
    this.scroller.scrollTop = before + step;
    if (this.scroller.scrollTop === before) return; // at the end already

    this.onScroll(this.point.x, this.point.y);
    this.frame = requestAnimationFrame(this.#step);
  };

  // Pixels to scroll this frame: 0 away from the edges, up to maxStep at
  // (or past) an edge of the box's visible part. Only above or below the box
  // itself: a pointer beside it (over a sidebar next to the list) is not
  // near its edge, whatever its height.
  #stepFor(x, y) {
    const { top, bottom, left, right } = visibleBounds(this.scroller);
    // Scrolled out of view (by the page around it): no edges to hold near.
    if (bottom <= top) return 0;
    if (x < left || x > right) return 0;
    const edge = Math.min(this.edge, (bottom - top) / 4);
    if (y < top + edge)
      return -Math.ceil(this.maxStep * strength(top + edge - y, edge));
    if (y > bottom - edge)
      return Math.ceil(this.maxStep * strength(y - (bottom - edge), edge));
    return 0;
  }
}

// 0 at the inner end of the edge zone, 1 at the edge and beyond, eased so
// the speed is easy to control near the start.
function strength(depth, edge) {
  const t = Math.min(depth / edge, 1);
  return t * t;
}

// The part of the box on screen. The screen is the visual viewport where the
// browser has one: pinch zoom or an on-screen keyboard can make it smaller
// than the layout viewport the pointer coordinates are given in.
function visibleBounds(scroller) {
  const screen = screenBounds();
  if (scroller === document.scrollingElement) return screen;
  const rect = scroller.getBoundingClientRect();
  return {
    top: Math.max(rect.top, screen.top),
    bottom: Math.min(rect.bottom, screen.bottom),
    left: Math.max(rect.left, screen.left),
    right: Math.min(rect.right, screen.right),
  };
}

function screenBounds() {
  const viewport = window.visualViewport;
  if (!viewport)
    return {
      top: 0,
      bottom: window.innerHeight,
      left: 0,
      right: window.innerWidth,
    };
  return {
    top: viewport.offsetTop,
    bottom: viewport.offsetTop + viewport.height,
    left: viewport.offsetLeft,
    right: viewport.offsetLeft + viewport.width,
  };
}

function scrollParent(element) {
  for (let node = element?.parentElement; node; node = node.parentElement) {
    const { overflowY } = getComputedStyle(node);
    if (/auto|scroll/.test(overflowY) && node.scrollHeight > node.clientHeight)
      return node;
  }
  return document.scrollingElement;
}
