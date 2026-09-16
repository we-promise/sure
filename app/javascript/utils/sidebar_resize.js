// Pure geometry helpers for the resizable app sidebars.
//
// Kept free of any DOM access so the clamping logic can be unit-tested in
// isolation. Must be kept in sync with
// test/javascript/utils/sidebar_resize_test.mjs.

// Width of the always-visible icon navbar to the left of the sidebars.
export const SIDEBAR_NAVBAR_WIDTH = 84;
// Smallest a sidebar may shrink to while still being usable.
export const SIDEBAR_MIN_WIDTH = 240;
// Minimum breathing room the center content must always keep so the dashboard
// stays legible no matter how wide the sidebars are dragged.
export const SIDEBAR_MIN_MAIN_WIDTH = 400;

export const SIDEBAR_DEFAULTS = { left: 320, right: 400 };
// Hard upper bounds per side, regardless of how much room is available.
export const SIDEBAR_ABS_MAX = { left: 480, right: 560 };

// Clamp a requested sidebar width to a value that respects the per-side bounds
// AND guarantees the center column keeps at least SIDEBAR_MIN_MAIN_WIDTH.
//
// rawWidth   - desired width in px (e.g. derived from the pointer position)
// viewportWidth - window.innerWidth
// otherWidth - current width of the opposite sidebar (0 if collapsed/hidden)
export function clampSidebarWidth(
  rawWidth,
  {
    viewportWidth,
    otherWidth = 0,
    navbarWidth = SIDEBAR_NAVBAR_WIDTH,
    min = SIDEBAR_MIN_WIDTH,
    minMain = SIDEBAR_MIN_MAIN_WIDTH,
    absMax = Number.POSITIVE_INFINITY,
  } = {},
) {
  const available = viewportWidth - navbarWidth - otherWidth - minMain;
  // Never let the computed max fall below `min`; if the viewport is genuinely
  // too small we pin to `min` and accept the squeeze rather than going invalid.
  const max = Math.max(min, Math.min(absMax, available));
  const clamped = Math.min(Math.max(rawWidth, min), max);
  return Math.round(clamped);
}
