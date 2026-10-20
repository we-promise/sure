// Positioning strategy for a Floating UI panel anchored to a trigger.
//
// A CSS size container (`container-type` other than `normal`) establishes a
// containing block for positioned descendants, so a `fixed` panel's
// viewport-relative coordinates get resolved against that container and the
// panel drifts away from its trigger. Panels inside one therefore use
// `absolute` coordinates; everywhere else `fixed` keeps the panel out of the
// ancestors' stacking and overflow contexts.
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
