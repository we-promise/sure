import { describe, it } from "node:test"
import assert from "node:assert/strict"

// Inline the function to avoid needing a bundler for ESM imports.
// Must be kept in sync with app/javascript/utils/sidebar_resize.js
const SIDEBAR_NAVBAR_WIDTH = 84
const SIDEBAR_MIN_WIDTH = 240
const SIDEBAR_MIN_MAIN_WIDTH = 400

function clampSidebarWidth(rawWidth, {
  viewportWidth,
  otherWidth = 0,
  navbarWidth = SIDEBAR_NAVBAR_WIDTH,
  min = SIDEBAR_MIN_WIDTH,
  minMain = SIDEBAR_MIN_MAIN_WIDTH,
  absMax = Infinity,
} = {}) {
  const available = viewportWidth - navbarWidth - otherWidth - minMain
  const max = Math.max(min, Math.min(absMax, available))
  const clamped = Math.min(Math.max(rawWidth, min), max)
  return Math.round(clamped)
}

describe("clampSidebarWidth", () => {
  // A roomy 1440px viewport with the opposite sidebar at its default width.
  const wide = { viewportWidth: 1440, otherWidth: 400 }

  describe("within bounds", () => {
    it("returns a width inside the allowed range unchanged", () => {
      assert.equal(clampSidebarWidth(320, wide), 320)
    })

    it("rounds fractional pointer widths", () => {
      assert.equal(clampSidebarWidth(321.6, wide), 322)
    })
  })

  describe("minimum width", () => {
    it("pins anything below the minimum up to the minimum", () => {
      assert.equal(clampSidebarWidth(100, wide), SIDEBAR_MIN_WIDTH)
    })

    it("pins negative values to the minimum", () => {
      assert.equal(clampSidebarWidth(-50, wide), SIDEBAR_MIN_WIDTH)
    })
  })

  describe("per-side absolute max", () => {
    it("caps at absMax even when more room is available", () => {
      // 1440 - 84 - 400 - 400 = 556 available, but absMax wins.
      assert.equal(clampSidebarWidth(900, { ...wide, absMax: 480 }), 480)
    })
  })

  describe("protecting the center column", () => {
    it("never lets the main area drop below the minimum", () => {
      // At 1024px with the other sidebar at 240, the most this side can take is
      // 1024 - 84 - 240 - 400 = 300px.
      const width = clampSidebarWidth(900, { viewportWidth: 1024, otherWidth: 240 })
      assert.equal(width, 300)
      const mainLeft = 1024 - 84 - 240 - width
      assert.equal(mainLeft, SIDEBAR_MIN_MAIN_WIDTH)
    })

    it("shrinks the allowance as the opposite sidebar grows", () => {
      const narrow = clampSidebarWidth(900, { viewportWidth: 1024, otherWidth: 300 })
      assert.equal(narrow, 240) // 1024 - 84 - 300 - 400 = 240
    })
  })

  describe("degenerate viewports", () => {
    it("falls back to the minimum when there is no room to give", () => {
      // available goes negative; we accept the squeeze rather than return junk.
      assert.equal(clampSidebarWidth(500, { viewportWidth: 600, otherWidth: 240 }), SIDEBAR_MIN_WIDTH)
    })
  })

  describe("default options", () => {
    it("treats a missing opposite sidebar as zero width", () => {
      // 1440 - 84 - 0 - 400 = 956 available, request honored.
      assert.equal(clampSidebarWidth(700, { viewportWidth: 1440 }), 700)
    })
  })
})
