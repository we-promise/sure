// Compact currency labels for chart axes ($950K, $1.05M) with just enough
// precision that every gridline reads differently and exactly.
//
// A fixed one-decimal compact format turns ticks 1.00M, 1.05M, 1.10M into
// "$1M", "$1.1M", "$1.1M": neighbouring lines look identical and the labels
// are rounded off. Here the number of decimals follows the tick spacing, and if
// even a few compact decimals cannot tell neighbours apart (ticks $50 apart on a
// $14M balance) the labels fall back to the full number ($14,223,250).
//
// Pure (Intl only, no d3/DOM) so it can be unit tested with `node --test`
// (test/javascript/utils/chart_axis_labels_test.mjs).

const MAX_FRACTION_DIGITS = 4;
// Ceiling for the full-number fallback, which is not tied to a compact unit
// (a BTC balance moves in steps of 0.00005).
const MAX_FULL_FRACTION_DIGITS = 8;

// Decimals needed to show a step exactly (0.25 -> 2), up to `max`.
function decimalsFor(step, max = MAX_FRACTION_DIGITS) {
  for (let digits = 0; digits <= max; digits++) {
    const scaled = step * 10 ** digits;
    // A step below one unit at this precision would "round" to zero: keep going.
    if (Math.round(scaled) !== 0 && Math.abs(scaled - Math.round(scaled)) < 1e-6) return digits;
  }
  return max;
}

// The unit Intl's compact notation uses for `largest` in this locale: 1e3 (K)
// in English, but 1e4 (万) in Chinese and Japanese, 1e5 (L) in en-IN. Read it
// back from a generously precise rendering instead of assuming thousands.
function unitFor(largest, locale, currency) {
  if (!(largest > 0)) return 1;

  const parts = buildFormatter(locale, currency, {
    notation: "compact",
    maximumFractionDigits: MAX_FRACTION_DIGITS,
  }).formatToParts(largest);
  const integer = parts.filter((p) => p.type === "integer").map((p) => p.value).join("");
  const fraction = parts.find((p) => p.type === "fraction")?.value;
  const shown = Number(fraction ? `${integer}.${fraction}` : integer);

  // Locales with non-Latin digits (ar-EG) can't be read back this way. Report
  // "unknown" rather than guessing a unit, so the caller shows full numbers.
  if (!(shown > 0)) return null;
  return 10 ** Math.round(Math.log10(largest / shown));
}

function buildFormatter(locale, currency, options) {
  const base = { minimumFractionDigits: 0, ...options };

  try {
    return new Intl.NumberFormat(locale || undefined, {
      ...base,
      style: "currency",
      currency,
    });
  } catch {
    // Missing/unknown currency code: still show a readable number.
    return new Intl.NumberFormat(locale || undefined, base);
  }
}

const unique = (labels) => new Set(labels).size === labels.length;

// Returns (value) => label for the given tick values.
export function compactAxisFormatter(ticks, currency, locale) {
  const finite = (ticks || []).filter(Number.isFinite);
  const largest = Math.max(0, ...finite.map(Math.abs));
  const steps = finite.slice(1).map((t, i) => Math.abs(t - finite[i])).filter((s) => s > 0);
  const step = steps.length > 0 ? Math.min(...steps) : 0;

  // Fewest decimals that show the tick spacing exactly, bumped until unique.
  // When even MAX_FRACTION_DIGITS cannot show the spacing exactly, compact
  // labels would be unique but rounded, so go straight to the full number.
  // A lone tick has no spacing, so give it all the precision compact allows.
  const unit = step > 0 ? unitFor(largest, locale, currency) : 1;
  let digits = MAX_FRACTION_DIGITS;
  if (step > 0) digits = unit ? decimalsFor(step / unit, MAX_FRACTION_DIGITS + 1) : MAX_FRACTION_DIGITS + 1;
  for (; digits <= MAX_FRACTION_DIGITS; digits++) {
    const formatter = buildFormatter(locale, currency, {
      notation: "compact",
      maximumFractionDigits: digits,
    });

    if (unique(finite.map((t) => formatter.format(t)))) {
      return (value) => formatter.format(value);
    }
  }

  // Compact formatting cannot separate these ticks: show the full number.
  const full = buildFormatter(locale, currency, {
    notation: "standard",
    maximumFractionDigits: step >= 1 ? 0 : decimalsFor(step, MAX_FULL_FRACTION_DIGITS),
  });
  return (value) => full.format(value);
}
