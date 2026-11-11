// Marks the page while a sidebar is animating or being dragged, as
// `<html data-layout-animating>`. Each frame of a sidebar's width change lays
// out everything beside it again, and a long list (an account's activity) takes
// most of a frame to lay out; while the mark is set, CSS lets rows that are off
// screen skip that (content-visibility: auto, on the activity row partials). It is not left
// on: that containment would clip the rows' fixed-position menus. A row with a
// menu or picker open (a trigger with aria-expanded="true") is left out of it
// meanwhile, since those stay open through a drag.
let holds = 0;

function apply() {
  if (holds > 0) {
    document.documentElement.dataset.layoutAnimating = "";
  } else {
    delete document.documentElement.dataset.layoutAnimating;
  }
}

// Marks the page until the caller releases it (a drag).
export function holdLayoutAnimating() {
  holds += 1;
  apply();
  let released = false;
  return () => {
    if (released) return;
    released = true;
    holds -= 1;
    apply();
  };
}

// Marks the page until `element`'s width and max-width transitions have
// ended (or `fallbackMs` passes, for a transition that never runs or ends). A
// toggle animates the width; a resize committed from the keyboard or a
// double-click animates the max-width that caps it, and the two can overlap.
// A toggle while the sidebar is still moving reverses its transition: the old
// one is cancelled and a new one runs. The element keeps one mark, renewed by
// each toggle or resize, counting the transitions that started and released
// when the last of them ends, or two frames after a cancellation that no new
// transition replaced.
const marks = new WeakMap();
const LAYOUT_PROPERTIES = ["width", "max-width"];

export function markLayoutAnimating(element, { fallbackMs = 600 } = {}) {
  let mark = marks.get(element);
  if (!mark) {
    const release = holdLayoutAnimating();
    const ours = (event) =>
      event.target === element &&
      LAYOUT_PROPERTIES.includes(event.propertyName);
    mark = {
      timer: null,
      running: 0,
      finish: () => {
        element.removeEventListener("transitionrun", mark.onRun);
        element.removeEventListener("transitionend", mark.onEnd);
        element.removeEventListener("transitioncancel", mark.onCancel);
        clearTimeout(mark.timer);
        marks.delete(element);
        release();
      },
      onRun: (event) => {
        if (ours(event)) mark.running += 1;
      },
      onEnd: (event) => {
        if (!ours(event)) return;
        mark.running = Math.max(0, mark.running - 1);
        if (mark.running === 0) mark.finish();
      },
      // A reversed toggle cancels its transition and starts another in the
      // same or the next frame; a cancellation nothing replaces (a drag
      // turning the transition off) ends the mark once that has had time.
      onCancel: (event) => {
        if (!ours(event)) return;
        mark.running = Math.max(0, mark.running - 1);
        if (mark.running > 0) return;
        requestAnimationFrame(() =>
          requestAnimationFrame(() => {
            if (marks.get(element) === mark && mark.running === 0)
              mark.finish();
          }),
        );
      },
    };
    element.addEventListener("transitionrun", mark.onRun);
    element.addEventListener("transitionend", mark.onEnd);
    element.addEventListener("transitioncancel", mark.onCancel);
    marks.set(element, mark);
  }
  clearTimeout(mark.timer);
  mark.timer = setTimeout(() => mark.finish(), fallbackMs);
}
