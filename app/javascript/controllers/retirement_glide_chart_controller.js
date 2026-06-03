import { Controller } from "@hotwired/stimulus"
import * as d3 from "d3"

// Glide-path chart for the retirement dashboard: portfolio value across
// age, with a ±1pp real-return band, a zero-savings (Walletburst) shadow,
// accumulation/drawdown phase shading, retire + Coast crossover markers,
// lump markers, and a hover tooltip showing the per-age income breakdown.
// Mirrors goal_projection_chart_controller's D3 / resize / theme idiom.
export default class extends Controller {
  static values = {
    data: Object,
    ariaLabel: { type: String, default: "Retirement glide path" },
    coveredLabel: { type: String, default: "Covered" },
    portfolioLabel: { type: String, default: "Portfolio" },
    stateLabel: { type: String, default: "State pension" },
    workplaceLabel: { type: String, default: "Workplace" },
    drawdownLabel: { type: String, default: "Portfolio drawdown" },
    totalLabel: { type: String, default: "Total / mo" },
    retireLabel: { type: String, default: "Retire · age" },
    coastLabel: { type: String, default: "Coast · age" }
  }

  connect() {
    this._draw()
    if (typeof ResizeObserver !== "undefined") {
      this._observer = new ResizeObserver(() => this._draw())
      this._observer.observe(this.element)
    }
    if (typeof MutationObserver !== "undefined") {
      this._themeObserver = new MutationObserver((m) => {
        if (m.some((x) => x.attributeName === "data-theme")) this._draw()
      })
      this._themeObserver.observe(document.documentElement, { attributes: true, attributeFilter: ["data-theme"] })
    }
    this._onTurbo = () => { if (!this.element.querySelector("svg")) this._draw() }
    document.addEventListener("turbo:render", this._onTurbo)
  }

  disconnect() {
    this._observer?.disconnect()
    this._themeObserver?.disconnect()
    document.removeEventListener("turbo:render", this._onTurbo)
  }

  _css(name) {
    return getComputedStyle(document.documentElement).getPropertyValue(name).trim()
  }

  _symbol() {
    return this.dataValue.currency_symbol || "$"
  }

  _short(v) {
    const abs = Math.abs(v)
    if (abs >= 1_000_000) { const s = Math.round(v / 100_000) / 10; return `${this._symbol()}${s}M` }
    if (abs >= 1_000) { const s = Math.round(v / 1_000); return `${this._symbol()}${s}K` }
    return `${this._symbol()}${Math.round(v)}`
  }

  _money(v) {
    return `${this._symbol()}${Math.round(v).toLocaleString()}`
  }

  _draw() {
    const data = this.dataValue
    if (!data || !data.series || data.series.length === 0) return

    const root = this.element
    root.innerHTML = ""
    if (getComputedStyle(root).position === "static") root.style.position = "relative"

    const width = root.clientWidth || 640
    const height = root.clientHeight || 320
    const yAxisVisible = width >= 360
    const margin = { top: 24, right: 16, bottom: 28, left: yAxisVisible ? 52 : 12 }
    const innerW = Math.max(0, width - margin.left - margin.right)
    const innerH = Math.max(0, height - margin.top - margin.bottom)

    const green = this._css("--color-green-600") || "#16a34a"
    const blue = this._css("--color-blue-500") || "#3b82f6"
    const violet = this._css("--color-violet-500") || "#8b5cf6"
    const border = this._css("--color-gray-300") || "#d1d5db"
    const secondary = this._css("--color-gray-500") || "#6b7280"
    const containerBg = this._css("--color-white") || "#ffffff"

    const ages = data.series.map((d) => d.age)
    const allValues = [
      ...data.series, ...(data.band_high || []), ...(data.shadow_series || [])
    ].map((d) => d.value)
    const yMax = Math.max(1, d3.max(allValues) || 1)

    const x = d3.scaleLinear().domain([ages[0], ages[ages.length - 1]]).range([margin.left, margin.left + innerW])
    const y = d3.scaleLinear().domain([0, yMax * 1.05]).range([margin.top + innerH, margin.top])

    const svg = d3.select(root).append("svg")
      .attr("width", width).attr("height", height)
      .attr("role", "img").attr("aria-label", this.ariaLabelValue)

    // Phase shading: accumulation (age < retire) tinted, drawdown plain.
    if (data.retire_age != null) {
      svg.append("rect")
        .attr("x", margin.left).attr("y", margin.top)
        .attr("width", Math.max(0, x(data.retire_age) - margin.left)).attr("height", innerH)
        .attr("fill", green).attr("opacity", 0.05)
    }

    // y gridlines + labels
    if (yAxisVisible) {
      y.ticks(4).forEach((t) => {
        svg.append("line")
          .attr("x1", margin.left).attr("x2", margin.left + innerW)
          .attr("y1", y(t)).attr("y2", y(t))
          .attr("stroke", border).attr("stroke-width", 1).attr("opacity", 0.5)
        svg.append("text")
          .attr("x", margin.left - 8).attr("y", y(t)).attr("dy", "0.32em")
          .attr("text-anchor", "end").attr("font-size", 11).attr("fill", secondary)
          .text(this._short(t))
      })
    }

    // x age labels (every ~10y)
    x.ticks(6).forEach((t) => {
      svg.append("text")
        .attr("x", x(t)).attr("y", margin.top + innerH + 18)
        .attr("text-anchor", "middle").attr("font-size", 11).attr("fill", secondary)
        .text(`age ${Math.round(t)}`)
    })

    // ±1pp band (area between band_low and band_high)
    if (data.band_low && data.band_high) {
      const byAge = {}
      data.band_low.forEach((d) => { byAge[d.age] = { lo: d.value } })
      data.band_high.forEach((d) => {
        byAge[d.age] = byAge[d.age] || {}
        byAge[d.age].hi = d.value
      })
      const bandData = Object.keys(byAge).map((a) => ({ age: +a, lo: byAge[a].lo, hi: byAge[a].hi }))
        .filter((d) => d.lo != null && d.hi != null).sort((a, b) => a.age - b.age)
      const bandArea = d3.area().x((d) => x(d.age)).y0((d) => y(d.lo)).y1((d) => y(d.hi)).curve(d3.curveMonotoneX)
      svg.append("path").datum(bandData).attr("fill", green).attr("opacity", 0.12).attr("d", bandArea)
    }

    // Walletburst (zero-savings) shadow — dashed gray
    if (data.shadow_series) {
      const line = d3.line().x((d) => x(d.age)).y((d) => y(d.value)).curve(d3.curveMonotoneX)
      svg.append("path").datum(data.shadow_series)
        .attr("fill", "none").attr("stroke", secondary).attr("stroke-width", 1.5)
        .attr("stroke-dasharray", "4 4").attr("opacity", 0.7).attr("d", line)
    }

    // Active plan — area + line
    const id = Math.random().toString(36).slice(2)
    const defs = svg.append("defs")
    const grad = defs.append("linearGradient").attr("id", `glide-${id}`).attr("x1", 0).attr("y1", 0).attr("x2", 0).attr("y2", 1)
    grad.append("stop").attr("offset", "0%").attr("stop-color", green).attr("stop-opacity", 0.18)
    grad.append("stop").attr("offset", "100%").attr("stop-color", green).attr("stop-opacity", 0)
    const area = d3.area().x((d) => x(d.age)).y0(margin.top + innerH).y1((d) => y(d.value)).curve(d3.curveMonotoneX)
    const line = d3.line().x((d) => x(d.age)).y((d) => y(d.value)).curve(d3.curveMonotoneX)
    svg.append("path").datum(data.series).attr("fill", `url(#glide-${id})`).attr("d", area)
    svg.append("path").datum(data.series).attr("fill", "none").attr("stroke", green)
      .attr("stroke-width", 2).attr("stroke-linejoin", "round").attr("d", line)

    const valueAt = (age) => {
      const pt = data.series.find((d) => d.age === age)
      return pt ? pt.value : null
    }

    // Retire marker — vertical dashed line + chip
    if (data.retire_age != null && data.retire_value != null) {
      svg.append("line")
        .attr("x1", x(data.retire_age)).attr("x2", x(data.retire_age))
        .attr("y1", margin.top).attr("y2", margin.top + innerH)
        .attr("stroke", secondary).attr("stroke-width", 1).attr("stroke-dasharray", "2 4")
      const label = svg.append("g").attr("transform", `translate(${x(data.retire_age) + 6}, ${margin.top + 6})`)
      label.append("text").attr("font-size", 10).attr("fill", secondary)
        .text(`${this.retireLabelValue} ${data.retire_age}`)
      label.append("text").attr("y", 14).attr("font-size", 12).attr("font-weight", 600)
        .attr("fill", this._css("--color-gray-900") || "#111").text(this._short(data.retire_value))
    }

    // Lump markers — purple vertical bars
    const lumps = data.lumps || []
    lumps.forEach((lump) => {
      svg.append("line")
        .attr("x1", x(lump.age)).attr("x2", x(lump.age))
        .attr("y1", y(valueAt(lump.age) ?? 0) - 14).attr("y2", y(valueAt(lump.age) ?? 0) + 14)
        .attr("stroke", violet).attr("stroke-width", 3)
    })

    // Coast crossover — blue ringed dot
    if (data.coast_age != null && valueAt(data.coast_age) != null) {
      svg.append("circle")
        .attr("cx", x(data.coast_age)).attr("cy", y(valueAt(data.coast_age)))
        .attr("r", 5).attr("fill", containerBg).attr("stroke", blue).attr("stroke-width", 3)
    }

    this._attachTooltip(svg, root, x, y, data, { margin, innerW, innerH, green, secondary, blue, violet, containerBg })
  }

  _attachTooltip(svg, root, x, y, data, opts) {
    const { margin, innerW, innerH, secondary, containerBg } = opts
    const incomeByAge = {}
    const incomeRows = data.income || []
    incomeRows.forEach((r) => { incomeByAge[r.age] = r })

    const tooltip = document.createElement("div")
    tooltip.className = "bg-container text-primary text-sm font-sans absolute p-3 rounded-xl shadow-lg shadow-border-xs pointer-events-none z-50 privacy-sensitive"
    tooltip.style.display = "none"
    tooltip.style.minWidth = "200px"
    root.appendChild(tooltip)

    const crosshair = svg.append("line")
      .attr("y1", margin.top).attr("y2", margin.top + innerH)
      .attr("stroke", secondary).attr("stroke-width", 1).attr("stroke-dasharray", "2 2")
      .attr("pointer-events", "none").style("display", "none")
    const dot = svg.append("circle").attr("r", 4).attr("fill", opts.green)
      .attr("stroke", containerBg).attr("stroke-width", 2).attr("pointer-events", "none").style("display", "none")

    const row = (label, value, color) => {
      const swatch = color ? `<span style="display:inline-block;width:8px;height:8px;border-radius:2px;background:${color};margin-right:6px"></span>` : ""
      return `<div class="flex items-center justify-between gap-4"><span class="text-secondary">${swatch}${label}</span><span class="tabular-nums">${value}</span></div>`
    }

    const showAt = (mx) => {
      // Snap to the nearest series point so the tooltip never no-ops at the
      // edges or if an integer age is ever skipped.
      const rawAge = x.invert(mx)
      let pt = null
      let best = Number.POSITIVE_INFINITY
      for (const d of data.series) {
        const dist = Math.abs(d.age - rawAge)
        if (dist < best) { best = dist; pt = d }
      }
      if (!pt) return
      const age = pt.age
      crosshair.attr("x1", x(age)).attr("x2", x(age)).style("display", null)
      dot.attr("cx", x(age)).attr("cy", y(pt.value)).style("display", null)

      const inc = incomeByAge[age]
      const covered = inc ? inc.covered : true
      const badge = `<span class="text-xs px-1.5 py-0.5 rounded ${covered ? "text-success" : "text-destructive"}">${covered ? `&#10003; ${this.coveredLabelValue}` : ""}</span>`
      let html = `<div class="flex items-center justify-between gap-4 mb-2"><span class="font-medium">Age ${age}</span>${badge}</div>`
      html += row(this.portfolioLabelValue, this._money(pt.value))
      if (inc) {
        html += `<div class="border-t border-tertiary my-2"></div>`
        if (inc.state > 0) html += row(this.stateLabelValue, `${this._money(inc.state / 12)}/mo`, opts.blue)
        if (inc.workplace > 0) html += row(this.workplaceLabelValue, `${this._money(inc.workplace / 12)}/mo`, opts.violet)
        if (inc.drawdown > 0) html += row(this.drawdownLabelValue, `${this._money(inc.drawdown / 12)}/mo`, opts.green)
        const totalMo = (inc.state + inc.workplace + inc.other + inc.drawdown) / 12
        html += `<div class="border-t border-tertiary my-2"></div>`
        html += row(this.totalLabelValue, `${this._money(totalMo)} / ${this._money(data.target_monthly)}`)
      }
      tooltip.innerHTML = html
      tooltip.style.display = "block"
      const tipW = tooltip.getBoundingClientRect().width
      tooltip.style.left = `${Math.min(root.clientWidth - tipW - 4, Math.max(4, x(age) + 12))}px`
      tooltip.style.top = `${margin.top + 4}px`
    }

    svg.append("rect")
      .attr("x", margin.left).attr("y", margin.top).attr("width", innerW).attr("height", innerH)
      .attr("fill", "transparent").style("cursor", "crosshair")
      .on("pointermove", (event) => showAt(d3.pointer(event)[0]))
      .on("pointerleave", () => {
        tooltip.style.display = "none"
        crosshair.style("display", "none")
        dot.style("display", "none")
      })
  }
}
