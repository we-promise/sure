// Single source of truth for the cursor-following tooltip used by the chart
// controllers (time-series, sankey, and goal-projection once it lands from the
// goals work). Keeping the visual contract here stops the bg / text / border /
// privacy-sensitive classes from drifting apart across the controllers, the way
// they had before (time-series was missing `text-primary` and `z-50`).
//
// This is the VISUAL contract only. Callers append their own behavioural
// classes (initial `opacity-0`, `top-0`, …) or set them via inline styles,
// because how each chart shows/hides and positions its tooltip differs.
//
// Not to be confused with DS::Tooltip — that is the info-icon hint primitive
// (bg-inverse, aria-describedby, anchored to a static trigger). This is a
// data-card surface created and updated inside D3 handler code.
// Visual target: the borderless soft-shadow card from the design reference —
// generous padding, large radius, no edge ring in light mode (the shadow alone
// defines the surface). Dark mode keeps a 1px alpha ring because a shadow is
// nearly invisible against dark surfaces and the card would otherwise melt
// into the chart background.
export const CHART_TOOLTIP_CLASSES =
  "bg-container text-primary text-sm font-sans absolute p-4 rounded-2xl shadow-xl theme-dark:ring-1 theme-dark:ring-alpha-white-200 pointer-events-none z-50 privacy-sensitive";

// Content conventions (kept here so the controllers stay aligned):
//   - context line (date / node title): `text-xs text-secondary mb-1`
//   - value figures: `font-medium tabular-nums`, secondary parentheticals in
//     `text-secondary`
export const CHART_TOOLTIP_CONTEXT_CLASSES = "text-xs text-secondary mb-1";
export const CHART_TOOLTIP_VALUE_CLASSES = "font-medium tabular-nums";

// Convenience factory for the raw-DOM idiom (no d3.select). Creates a hidden
// tooltip div carrying the shared contract and appends it to `parent`.
export function createChartTooltip(parent) {
  const tooltip = document.createElement("div");
  tooltip.className = CHART_TOOLTIP_CLASSES;
  tooltip.style.display = "none";
  parent.appendChild(tooltip);
  return tooltip;
}
