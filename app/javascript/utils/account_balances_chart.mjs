// Pure helpers for the Account Balances widget (account_balances_chart_controller.js),
// kept free of d3 and the DOM so they can be tested with `node --test`.

export const DAY = 86400000

export function parseDay(isoDate) {
  const [year, month, day] = isoDate.split("-").map(Number)
  return new Date(Date.UTC(year, month - 1, day))
}

export function formatDay(date) {
  return date.toISOString().slice(0, 10)
}

// The same day of the month `months` later, clamped to the month's last day.
export function addMonths(date, months) {
  const target = new Date(Date.UTC(date.getUTCFullYear(), date.getUTCMonth() + months, 1))
  const lastDay = new Date(Date.UTC(target.getUTCFullYear(), target.getUTCMonth() + 1, 0)).getUTCDate()
  target.setUTCDate(Math.min(date.getUTCDate(), lastDay))
  return target
}

// The family's date format without its day, for month ticks:
// "%d.%m.%Y" -> "%m.%Y", "%m/%d/%Y" -> "%m/%Y", "%Y-%m-%d" -> "%Y-%m".
export function monthFormatFor(dateFormat) {
  // A separator is any one non-letter character next to the day token.
  if (/^%[de]/.test(dateFormat)) return dateFormat.replace(/^%[de][^%a-zA-Z]?/, "")
  return dateFormat.replace(/[^%a-zA-Z]?%[de]/, "")
}

// Prefix and suffix around a number for a Rails currency format such as
// "%u%n" ($1), "%u %n" (CHF 1) or "%n %u" (1 €).
export function currencyAffixes(format, unit) {
  const [before, after] = String(format || "%u%n").split("%n")
  return [before.replace("%u", unit), (after || "").replace("%u", unit)]
}

// The form of a Rails plural hash ({ one:, few:, many:, other: }) that the
// locale's plural rules pick for `count`, falling back to `other` when a
// translation lacks that form.
export function pluralForm(forms, count, locale = "en") {
  return forms[new Intl.PluralRules(locale).select(count)] ?? forms.other
}

// Fills "%{name}" placeholders in a translated string.
export function interpolate(template, vars = {}) {
  return String(template).replace(/%\{(\w+)\}/g, (match, key) => (key in vars ? String(vars[key]) : match))
}

// History rows before today, then one row per day from today to the end of
// the forecast. Today's row holds each account's recorded balance; each later
// row adds the events (bills, future-dated transactions) due that day, and the
// first projected day also takes the ones due today.
// Row: { date, forecast, values: { accountId: amount }, events: [...] }.
export function buildRows(data, horizonMonths) {
  const today = parseDay(data.today)
  const rows = []
  data.dates.forEach((isoDate, i) => {
    const date = parseDay(isoDate)
    if (date >= today) return
    const values = {}
    for (const account of data.accounts) values[account.id] = account.history[i] ?? 0
    rows.push({ date, forecast: false, events: [], values })
  })

  const end = horizonMonths > 0 ? addMonths(today, horizonMonths) : today
  const cursors = data.accounts.map((account) => ({ id: account.id, value: account.start, events: account.events, next: 0 }))
  for (let time = +today; time <= +end; time += DAY) {
    const date = new Date(time)
    const key = formatDay(date)
    const events = []
    const values = {}
    for (const cursor of cursors) {
      // Today's row is the recorded balance; events due today (an unpaid
      // bill) apply from the first projected day on, once.
      while (time > +today && cursor.next < cursor.events.length && cursor.events[cursor.next].date <= key) {
        const event = cursor.events[cursor.next++]
        cursor.value += event.amount
        events.push({ ...event, account: cursor.id })
      }
      values[cursor.id] = cursor.value
    }
    rows.push({ date, forecast: time > +today, events, values })
  }
  return { rows, today }
}

// Stacks each row's values: negative balances hang below zero, and the
// positive ones stack up from that lowest point, so the top edge of the stack
// is the row's total. Returns one array per key of [y0, y1] points carrying
// `data` (the row) and `negative`.
export function stackRows(rows, keys) {
  const series = keys.map((key) => Object.assign([], { key }))
  for (const row of rows) {
    let below = 0
    let above = keys.reduce((sum, key) => sum + Math.min(0, row.values[key]), 0)
    keys.forEach((key, i) => {
      const value = row.values[key]
      const point = value < 0 ? [below + value, below] : [above, above + value]
      if (value < 0) below += value
      else above += value
      point.data = row
      point.negative = value < 0
      series[i].push(point)
    })
  }
  return series
}

// An area drawn with a `defined` filter per sign closes each run at its last
// point, so with a step curve a run is one day short and a one-day run has
// no width. Ends every run with a copy of its last point at the next row's
// date (same sign), so each balance is drawn through the following date.
export function extendSignRuns(points) {
  const extended = []
  points.forEach((point, i) => {
    extended.push(point)
    const next = points[i + 1]
    if (next && next.negative !== point.negative) {
      extended.push(Object.assign([...point], { data: { ...point.data, date: next.data.date }, negative: point.negative }))
    }
  })
  return extended
}

// Greedy left-to-right clustering of points sorted by x: a point closer than
// `minGap` px to the first point of the current cluster joins it.
export function clusterByDistance(points, minGap) {
  const clusters = []
  for (const point of points) {
    const current = clusters[clusters.length - 1]
    if (current && point.x - current.x0 < minGap) {
      current.members.push(point)
      current.x = current.members.reduce((sum, member) => sum + member.x, 0) / current.members.length
    } else {
      clusters.push({ x0: point.x, x: point.x, members: [point] })
    }
  }
  return clusters
}

// Index where a list of weighted blocks splits into two columns of about
// equal weight; weights are fixed per block so the split never moves when a
// block opens or closes.
export function columnSplit(weights) {
  const total = weights.reduce((sum, weight) => sum + weight, 0)
  let running = 0
  for (let i = 0; i < weights.length; i++) {
    if (running >= total / 2) return i
    running += weights[i]
  }
  return weights.length
}
