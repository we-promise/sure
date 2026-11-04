import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { compactAxisFormatter } from "../../../app/javascript/utils/chart_axis_labels.mjs";

const labelsFor = (ticks, currency = "USD") => {
  const format = compactAxisFormatter(ticks, currency, "en-US");
  return ticks.map(format);
};

describe("compactAxisFormatter", () => {
  it("keeps coarse axes short, like the spending chart's", () => {
    assert.deepEqual(labelsFor([0, 20, 40, 60, 80, 100, 120]), ["$0", "$20", "$40", "$60", "$80", "$100", "$120"]);
    assert.deepEqual(labelsFor([0, 500, 1000, 1500, 2000]), ["$0", "$500", "$1K", "$1.5K", "$2K"]);
    assert.deepEqual(labelsFor([110000, 111000, 112000, 113000, 114000, 115000]), ["$110K", "$111K", "$112K", "$113K", "$114K", "$115K"]);
  });

  it("adds decimals when the tick spacing needs them, so neighbours never repeat", () => {
    // Fixed one-decimal compact format printed these as $1M, $1.1M, $1.1M ...
    assert.deepEqual(labelsFor([1000000, 1050000, 1100000, 1150000]), ["$1M", "$1.05M", "$1.1M", "$1.15M"]);
    assert.deepEqual(labelsFor([1998000, 2000000, 2002000, 2004000]), ["$1.998M", "$2M", "$2.002M", "$2.004M"]);
  });

  it("shows every tick exactly, not rounded to a neighbouring value", () => {
    // Unique but rounded labels ($100.3K for 100,250) would be misleading.
    assert.deepEqual(labelsFor([100000, 100250, 100500, 100750]), ["$100K", "$100.25K", "$100.5K", "$100.75K"]);
  });

  it("handles negative and zero-crossing axes", () => {
    assert.deepEqual(labelsFor([-5000, 0, 5000]), ["-$5K", "$0", "$5K"]);
    assert.deepEqual(labelsFor([-1500000, -1000000, -500000, 0]), ["-$1.5M", "-$1M", "-$500K", "$0"]);
  });

  it("falls back to a plain compact number for a missing or invalid currency", () => {
    assert.deepEqual(labelsFor([1000, 2000], null), ["1K", "2K"]);
    assert.deepEqual(labelsFor([1000, 2000], "NOPE"), ["1K", "2K"]);
  });

  it("falls back to the full number when compact decimals cannot separate neighbours", () => {
    // $50 apart on a $14M balance: five compact decimals would be needed.
    assert.deepEqual(labelsFor([14223200, 14223250, 14223300]), ["$14,223,200", "$14,223,250", "$14,223,300"]);
  });

  it("copes with a single tick or none", () => {
    assert.deepEqual(labelsFor([5000]), ["$5K"]);
    assert.equal(typeof compactAxisFormatter([], "USD", "en-US"), "function");
  });

  it("never prints duplicate labels for evenly spaced ticks, across magnitudes and spreads", () => {
    let seed = 7;
    const random = () => (seed = (seed * 1664525 + 1013904223) % 4294967296) / 4294967296;
    const niceMultipliers = [1, 2, 5];

    for (let i = 0; i < 1000; i++) {
      // A 1/2/5 x 10^n step from 0.01 up to 5M, over balances up to ~$30M.
      const step = niceMultipliers[Math.floor(random() * 3)] * 10 ** (Math.floor(random() * 9) - 2);
      const base = Math.floor((random() * 3e7) / step) * step;
      const ticks = Array.from({ length: 4 + Math.floor(random() * 3) }, (_, n) => Number((base + n * step).toPrecision(12)));
      const labels = labelsFor(ticks);

      assert.equal(new Set(labels).size, labels.length, `duplicate labels ${labels.join(" | ")} for ticks ${ticks.join(", ")}`);
    }
  });
});
