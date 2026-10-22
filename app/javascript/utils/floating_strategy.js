// Positioning strategy for a Floating UI panel anchored to a trigger.
//
// Floating UI treats a size container (`container-type` other than `normal`)
// as the containing block of a fixed panel, while the browser uses the
// viewport. The panel therefore lands offset by the container's position.
// Absolute positioning resolves consistently in both, so use it inside a
// size container and keep fixed positioning elsewhere.
export function floatingStrategy(element) {
  for (
    let ancestor = element.parentElement;
    ancestor;
    ancestor = ancestor.parentElement
  ) {
    if (getComputedStyle(ancestor).containerType !== "normal")
      return "absolute";
  }
  return "fixed";
}
