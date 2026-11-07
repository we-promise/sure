// A click closes a dialog only when it landed outside the content and the press
// that produced it did not start inside the content. Selecting text inside the
// dialog and releasing the mouse over the backdrop fires a click on the backdrop,
// which must not be treated as a click outside.
export function shouldCloseOnClick(pressTarget, clickTarget, content) {
  if (pressTarget && content.contains(pressTarget)) return false;
  return !content.contains(clickTarget);
}
