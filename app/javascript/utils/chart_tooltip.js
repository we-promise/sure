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
// The surface itself lives in the design system as `.chart-tooltip`
// (sure-design-system/components.css): container bg, 10px radius, 12x14
// padding, hairline ring composed with a soft 8/24 drop shadow, 80ms
// left/top glide. It's a component class because Tailwind shadow utilities
// can't compose a ring with a custom drop shadow. This constant adds the
// behavioural classes shared by every chart tooltip.
export const CHART_TOOLTIP_CLASSES =
  "chart-tooltip text-primary text-sm font-sans absolute pointer-events-none z-50 privacy-sensitive";

// Content conventions (kept here so the controllers stay aligned):
//   - context line (date / node title): `text-xs text-secondary mb-1`
//   - money / numeric figures: tabular-nums so digits don't jitter while the
//     scrubber moves (sans, not mono — the app's money convention everywhere
//     else); secondary parentheticals in `text-secondary`
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
