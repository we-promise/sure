import { describe, it } from "node:test"
import assert from "node:assert/strict"
import { formatLocale } from "../../vendor/javascript/d3-format.js"
import {
  addMonths,
  buildLanePoints,
  buildRows,
  clusterByDistance,
  columnSplit,
  currencyAffixes,
  excludedFromSettings,
  extendSignRuns,
  formatDay,
  groupingFor,
  interpolate,
  monthFormatFor,
  parseDay,
  pluralForm,
  selectionToSave,
  stackRows,
  zoomTarget,
} from "../../app/javascript/utils/account_balances_chart.mjs"

describe("addMonths", () => {
  it("keeps the day of the month, clamped to shorter months", () => {
    assert.equal(formatDay(addMonths(parseDay("2026-01-31"), 1)), "2026-02-28")
    assert.equal(formatDay(addMonths(parseDay("2026-11-22"), 3)), "2027-02-22")
  })
})

describe("monthFormatFor", () => {
  it("drops the day and one separator from every family date format", () => {
    const cases = {
      "%m-%d-%Y": "%m-%Y",
      "%d.%m.%Y": "%m.%Y",
      "%d-%m-%Y": "%m-%Y",
      "%Y-%m-%d": "%Y-%m",
      "%d/%m/%Y": "%m/%Y",
      "%Y/%m/%d": "%Y/%m",
      "%m/%d/%Y": "%m/%Y",
      "%e/%m/%Y": "%m/%Y",
      "%Y.%m.%d": "%Y.%m",
      "%Y%m%d": "%Y%m",
      "%d %b %Y": "%b %Y",
    }
    for (const [dateFormat, month] of Object.entries(cases)) assert.equal(monthFormatFor(dateFormat), month, dateFormat)
  })
})

describe("currencyAffixes", () => {
  it("places the unit as the currency format says", () => {
    assert.deepEqual(currencyAffixes("%u%n", "$"), ["$", ""])
    assert.deepEqual(currencyAffixes("%u %n", "CHF"), ["CHF ", ""])
    assert.deepEqual(currencyAffixes("%n %u", "€"), ["", " €"])
  })
})

describe("pluralForm", () => {
  const forms = { one: "one", few: "few", many: "many", other: "other" }

  it("picks the locale's form, including the extra forms of Slavic languages", () => {
    assert.equal(pluralForm(forms, 1, "en"), "one")
    assert.equal(pluralForm(forms, 5, "en"), "other")
    assert.equal(pluralForm(forms, 3, "pl"), "few")
    assert.equal(pluralForm(forms, 5, "pl"), "many")
  })

  it("falls back to other when a translation lacks the form", () => {
    assert.equal(pluralForm({ one: "one", other: "other" }, 3, "pl"), "other")
  })
})

describe("groupingFor", () => {
  // The vendored d3-format the browser uses; it cycles the grouping array.
  const format = (moneyFormat) =>
    formatLocale({ decimal: ".", thousands: ",", grouping: groupingFor(moneyFormat), currency: ["", ""] }).format(",.0f")

  it("groups by three", () => {
    assert.equal(format({ indian_grouping: false })(1234567890), "1,234,567,890")
  })

  it("groups 3-then-2 all the way for Indian grouping", () => {
    const indian = format({ indian_grouping: true })
    assert.equal(indian(123456), "1,23,456")
    assert.equal(indian(12345678), "1,23,45,678")
    assert.equal(indian(1234567890123), "12,34,56,78,90,123")
  })
})

describe("selectionToSave / excludedFromSettings", () => {
  const all = Array.from({ length: 250 }, (_, i) => `a${i}`)

  it("saves the shorter list, so None fits however many accounts there are", () => {
    const none = selectionToSave(new Set(all), all)
    assert.deepEqual(none, { hidden_account_ids: [], shown_account_ids: [] })
    assert.equal(excludedFromSettings(none, all).size, 250)

    const few = selectionToSave(new Set(["a1", "a2"]), all)
    assert.deepEqual(few, { hidden_account_ids: ["a1", "a2"], shown_account_ids: null })
    assert.deepEqual([...excludedFromSettings(few, all)], ["a1", "a2"])
  })

  it("round-trips a mostly hidden selection through the shown list", () => {
    const hidden = new Set(all.slice(1))
    const saved = selectionToSave(hidden, all)
    assert.deepEqual(saved.shown_account_ids, ["a0"])
    assert.deepEqual([...excludedFromSettings(saved, all)].sort(), [...hidden].sort())
  })
})

describe("buildLanePoints", () => {
  const recorded = { date: "2026-12-05", account: "a", amount: -10 }
  const planned = { date: "2026-12-05", account: "a", amount: -20, source: "bill" }

  it("puts a day's recorded and planned items on one spot at day level", () => {
    const points = buildLanePoints([recorded], [planned], false)
    assert.equal(points.length, 2)
    assert.equal(points[0].t, points[1].t)
  })

  it("spreads recorded and planned items of a day apart together once zoomed in", () => {
    const points = buildLanePoints([recorded], [planned], true)
    assert.equal(points.length, 2)
    assert.notEqual(points[0].t, points[1].t)
    assert.deepEqual(points.map((p) => p.planned).sort(), [false, true])
  })
})

describe("zoomTarget", () => {
  const DAY_MS = 86400000
  it("zooms into a range narrower than the view", () => {
    assert.deepEqual(zoomTarget(0, DAY_MS, [0, 10 * DAY_MS], DAY_MS / 4), [0, DAY_MS])
  })

  it("returns null when zooming cannot narrow the view any further", () => {
    assert.equal(zoomTarget(0, DAY_MS / 100, [0, DAY_MS / 4], DAY_MS / 4), null)
  })
})

describe("interpolate", () => {
  it("fills known placeholders and leaves unknown ones", () => {
    assert.equal(interpolate("%{shown} of %{count} shown", { shown: 3, count: 9 }), "3 of 9 shown")
    assert.equal(interpolate("before %{date}", {}), "before %{date}")
  })
})

describe("buildRows", () => {
  const data = {
    today: "2026-11-22",
    dates: ["2026-11-20", "2026-11-21", "2026-11-22"],
    accounts: [
      { id: "checking", start: 100, history: [80, 90, 95], events: [{ date: "2026-11-24", amount: -30, name: "Rent" }] },
      { id: "card", start: -50, history: [-40, -45, -45], events: [] },
    ],
  }

  it("uses history before today and today's recorded balance from today on", () => {
    const { rows } = buildRows(data, 0)
    assert.deepEqual(rows.map((r) => formatDay(r.date)), ["2026-11-20", "2026-11-21", "2026-11-22"])
    assert.equal(rows[2].values.checking, 100, "today is the recorded balance, not the history point")
    assert.equal(rows.at(-1).forecast, false)
  })

  it("applies each event on its own day and keeps it on that day's row", () => {
    const { rows } = buildRows(data, 1)
    const day = (iso) => rows.find((r) => formatDay(r.date) === iso)
    assert.equal(day("2026-11-23").values.checking, 100)
    assert.equal(day("2026-11-24").values.checking, 70)
    assert.equal(day("2026-11-24").events[0].account, "checking")
    assert.equal(formatDay(rows.at(-1).date), "2026-12-22")
    assert.equal(rows.at(-1).forecast, true)
  })
})

describe("buildRows with a bill due today", () => {
  const data = {
    today: "2026-11-22",
    dates: ["2026-11-21"],
    accounts: [{ id: "checking", start: 100, history: [100], events: [{ date: "2026-11-22", amount: -30, name: "Rent" }] }],
  }

  it("keeps today's row at the recorded balance, forecast off or on", () => {
    for (const horizon of [0, 1]) {
      const today = buildRows(data, horizon).rows.find((r) => formatDay(r.date) === "2026-11-22")
      assert.equal(today.values.checking, 100, `horizon ${horizon}`)
      assert.equal(today.events.length, 0)
    }
  })

  it("applies the due-today bill once, on the first projected day", () => {
    const { rows } = buildRows(data, 1)
    const tomorrow = rows.find((r) => formatDay(r.date) === "2026-11-23")
    assert.equal(tomorrow.values.checking, 70)
    assert.deepEqual(tomorrow.events.map((e) => e.name), ["Rent"])
    assert.equal(rows.filter((r) => r.events.some((e) => e.name === "Rent")).length, 1)
  })
})

describe("stackRows", () => {
  it("hangs negatives below zero and stacks positives from the lowest point", () => {
    const rows = [{ values: { savings: 100, checking: 40, card: -30 } }]
    const [savings, checking, card] = stackRows(rows, ["savings", "checking", "card"])
    assert.deepEqual([card[0][0], card[0][1]], [-30, 0])
    assert.equal(card[0].negative, true)
    assert.deepEqual([savings[0][0], savings[0][1]], [-30, 70])
    assert.deepEqual([checking[0][0], checking[0][1]], [70, 110], "the top edge is the total (100 + 40 - 30)")
  })
})

describe("extendSignRuns", () => {
  it("ends each run of one sign at the next row's date, so a one-day flip keeps its width", () => {
    const day = (d) => parseDay(`2026-11-${d}`)
    const rows = [20, 21, 22].map((d, i) => ({ date: day(d), values: { a: [50, -20, 50][i] } }))
    const [points] = stackRows(rows, ["a"])
    const extended = extendSignRuns(points)
    const span = (negative) =>
      extended.filter((p) => p.negative === negative).map((p) => formatDay(p.data.date))

    assert.deepEqual(span(true), ["2026-11-21", "2026-11-22"], "the -20 day is drawn from the 21st to the 22nd")
    assert.deepEqual(span(false), ["2026-11-20", "2026-11-21", "2026-11-22"], "the first +50 run reaches the 21st")
    assert.equal(extended.at(-1), points.at(-1), "the last point is untouched")
  })
})

describe("clusterByDistance", () => {
  it("merges points closer than the gap to the cluster's first point", () => {
    const clusters = clusterByDistance([{ x: 0 }, { x: 10 }, { x: 19 }, { x: 40 }], 20)
    assert.deepEqual(clusters.map((c) => c.members.length), [3, 1])
  })
})

describe("columnSplit", () => {
  it("splits where the running weight first reaches half", () => {
    assert.equal(columnSplit([3, 3, 4, 8, 2]), 3)
    assert.equal(columnSplit([5]), 1)
  })
})
