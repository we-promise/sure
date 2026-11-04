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

// Decimals needed to show a step exactly (0.25 -> 2); capped.
function decimalsFor(step) {
  for (let digits = 0; digits <= MAX_FRACTION_DIGITS; digits++) {
    const scaled = step * 10 ** digits;
    if (Math.abs(scaled - Math.round(scaled)) < 1e-6) return digits;
  }
  return MAX_FRACTION_DIGITS;
}

function unitFor(largest) {
  if (largest >= 1e9) return 1e9;
  if (largest >= 1e6) return 1e6;
  if (largest >= 1e3) return 1e3;
  return 1;
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
  let digits = step > 0 ? decimalsFor(step / unitFor(largest)) : 0;
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
    maximumFractionDigits: step >= 1 ? 0 : decimalsFor(step),
  });
  return (value) => full.format(value);
}
