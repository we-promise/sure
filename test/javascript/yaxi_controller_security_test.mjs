import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import { describe, it } from "node:test"

const source = readFileSync(
  new URL("../../app/javascript/controllers/yaxi_controller.js", import.meta.url),
  "utf8",
)

describe("YAXI browser state", () => {
  it("stores credentials only through the encrypted Routex storage helper", () => {
    assert.match(source, /storeCredentials\(/)
    assert.doesNotMatch(source, /(?:localStorage|sessionStorage)\.setItem\([^)]*credentials/s)
  })

  it("removes credentials before serializing redirect state", () => {
    assert.match(source, /const \{ credentials, \.\.\.resumableState \} = state/)
    assert.match(source, /JSON\.stringify\(\{ \.\.\.resumableState, redirectContext: context \}\)/)
  })

  it("preserves the original balances ticket across transaction redirects", () => {
    assert.match(source, /balancesTicketId: this\.balancesTicketIdValue/)
    assert.match(source, /balances_ticket_id: state\.balancesTicketId/)
  })

  it("deletes redirect state before resuming authorization", () => {
    assert.match(source, /sessionStorage\.removeItem\(this\.redirectStorageKey\(\)\)/)
  })

  it("does not expose internal error messages to users", () => {
    assert.match(source, /error\.userMessage \|\| this\.message\("request_failed"\)/)
    assert.doesNotMatch(source, /error\.userMessage \|\| error\.message/)
  })
})
