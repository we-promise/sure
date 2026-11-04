require "test_helper"

class StashawayAccount::EntryPlanTest < ActiveSupport::TestCase
  include StashawayTestHelper

  test "flows, income, fees and month-end returns add up to the portfolio value" do
    goal = stashaway_goal("G1",
      transactions: [
        stashaway_row("d1", "2026-01-10", "Deposit", 1000),
        stashaway_row("f1", "2026-02-05", "Fee", -1, description: "2026-01"),
        stashaway_row("x1", "2026-02-06", "Buy", -500),
        stashaway_row("r1", "2026-02-07", "Entitlement", 3, description: "Dividend receivable", code: "ABC"),
        stashaway_row("e1", "2026-02-08", "Entitlement", 2.5, description: "Dividend received", code: "ABC"),
        stashaway_row("w1", "2026-02-20", "Withdrawal", -100)
      ],
      nav: { "SGD" => stashaway_daily("2026-01-10", "2026-02-15") { |d| d <= "2026-01-30" ? 1000 : (d == "2026-01-31" ? 1010 : 1020) } })

    plan = stashaway_plan([ goal ])

    assert plan.applicable
    assert_equal Date.new(2026, 2, 15), plan.last_nav_date
    assert_equal 1020, plan.final_nav
    assert_equal [
      "2026-01-10 Deposit -1000",
      "2026-01-31 Returns (month-end adjustment, 2026-01) -10",
      "2026-02-05 Management fee (Jan 2026) 1",
      "2026-02-08 Dividend received ABC -2.5",
      "2026-02-15 Returns (month-to-date adjustment, 2026-02) -8.5"
    ], stashaway_plan_lines(plan.entries)
    assert_equal 1020, -plan.entries.sum(&:amount)
    assert_equal [ "tx:w1" ], plan.pending.map(&:external_id), "a row after the latest value day waits"
    assert_equal "ret:2026-01", plan.entries.find { |entry| entry.kind == :returns }.external_id
    assert_equal [ "tx:d1", "ret:2026-01", "tx:f1", "tx:e1", "ret:2026-02" ], plan.entries.map(&:external_id)
    assert_equal [ nil, "Investment Returns", "Fees", "Income", "Investment Returns" ], plan.entries.map(&:category)
    assert_equal [ "Contribution", nil, nil, nil, nil ], plan.entries.map(&:activity_label)
    assert_equal "Withdrawal", plan.pending.sole.activity_label
  end

  test "foreign-currency rows convert at the goal's own value-implied rate" do
    goal = stashaway_goal("G2",
      transactions: [
        stashaway_row("d1", "2026-03-02", "Deposit", 1350),
        stashaway_row("e1", "2026-03-10", "Entitlement", 10, "USD", description: "Dividend received", code: "XLE")
      ],
      nav: {
        "SGD" => stashaway_daily("2026-03-02", "2026-03-31") { 1350 },
        "USD" => stashaway_daily("2026-03-02", "2026-03-31") { 1000 }
      })

    plan = stashaway_plan([ goal ])
    dividend = plan.entries.find { |entry| entry.kind == :income }

    assert_equal "Dividend received XLE (USD 10.00 @ 1.35)", dividend.name
    assert_equal BigDecimal("-13.5"), dividend.amount
    assert_equal 1350, -plan.entries.sum(&:amount)
  end

  test "a foreign-currency row uses the rate of the nearest earlier day, rounded to four places" do
    sgd = stashaway_daily("2026-03-01", "2026-03-31") { |d| d < "2026-03-16" ? 1277.2349 : 1300 }
    usd = stashaway_daily("2026-03-01", "2026-03-31") { 1000 }
    sgd.reject! { |point| point["date"].start_with?("2026-03-16") }
    goal = stashaway_goal("G2",
      transactions: [ stashaway_row("e1", "2026-03-16", "Entitlement", 3.56, "USD", description: "Dividend received") ],
      nav: { "SGD" => sgd, "USD" => usd })

    dividend = stashaway_plan([ goal ]).entries.find { |entry| entry.kind == :income }

    assert_equal "Dividend received (USD 3.56 @ 1.2772)", dividend.name
    assert_equal BigDecimal("-4.55"), dividend.amount
  end

  test "a foreign-currency row without a rate is left to the returns adjustment" do
    goal = stashaway_goal("G2",
      transactions: [
        stashaway_row("d1", "2026-03-02", "Deposit", 100),
        stashaway_row("e1", "2026-03-10", "Entitlement", 10, "USD", description: "Dividend received")
      ],
      nav: { "SGD" => stashaway_daily("2026-03-02", "2026-03-31") { 113.5 } })

    plan = stashaway_plan([ goal ])

    assert_equal [ "tx:d1", "ret:2026-03" ], plan.entries.map(&:external_id)
    assert_match(/no USD→SGD rate/, plan.warnings.sole)
    assert_equal BigDecimal("113.5"), -plan.entries.sum(&:amount)
  end

  test "a row without a StashAway transaction id is left to the returns adjustment" do
    unidentified = stashaway_row("d2", "2026-01-12", "Deposit", 40)
    unidentified["transactions"].first["id"] = nil
    goal = stashaway_goal("G1",
      transactions: [ stashaway_row("d1", "2026-01-10", "Deposit", 100), unidentified ],
      nav: { "SGD" => stashaway_daily("2026-01-10", "2026-01-31") { |d| d < "2026-01-12" ? 100 : 140 } })

    plan = stashaway_plan([ goal ])

    assert_equal [ "tx:d1", "ret:2026-01" ], plan.entries.map(&:external_id)
    assert_match(/no StashAway transaction id/, plan.warnings.sole)
    assert_equal 140, -plan.entries.sum(&:amount)
  end

  test "moves between an archived and an active portfolio of one account are dropped, and both are valued" do
    archived = stashaway_goal("A", state: "ARCHIVED", name: "Simple SGD",
      transactions: [ stashaway_row("d1", "2026-01-05", "Deposit", 50), stashaway_row("w1", "2026-01-20", "Withdrawal", -50, description: "Full Transfer") ],
      nav: { "SGD" => stashaway_daily("2026-01-05", "2026-02-10") { |d| d < "2026-01-20" ? 50 : 0 } })
    active = stashaway_goal("B", name: "Simple SGD",
      transactions: [ stashaway_row("d2", "2026-01-20", "Deposit", 50) ],
      nav: { "SGD" => stashaway_daily("2026-01-20", "2026-02-10") { 52 } })

    plan = stashaway_plan([ archived, active ])

    assert_equal [ "2026-01-05 Deposit -50", "2026-01-31 Returns (month-end adjustment, 2026-01) -2" ], stashaway_plan_lines(plan.entries)
    assert_equal [ Date.new(2026, 2, 10), 52 ], [ plan.last_nav_date, plan.expected_balance ]
    assert_empty plan.warnings
  end

  test "a same-day equal withdrawal and deposit StashAway does not mark as a transfer both stay" do
    archived = stashaway_goal("A", state: "ARCHIVED", name: "Simple SGD",
      transactions: [ stashaway_row("d1", "2026-01-05", "Deposit", 50), stashaway_row("w1", "2026-01-20", "Withdrawal", -50) ],
      nav: { "SGD" => stashaway_daily("2026-01-05", "2026-02-10") { |d| d < "2026-01-20" ? 50 : 0 } })
    active = stashaway_goal("B", name: "Simple SGD",
      transactions: [ stashaway_row("d2", "2026-01-20", "Deposit", 50) ],
      nav: { "SGD" => stashaway_daily("2026-01-20", "2026-02-10") { 52 } })

    lines = stashaway_plan_lines(stashaway_plan([ archived, active ]).entries)

    assert_includes lines, "2026-01-20 Withdrawal 50"
    assert_includes lines, "2026-01-20 Deposit -50"
    assert_equal 4, lines.size
  end

  test "a deposit sharing the withdrawal's operation id is the one dropped with it" do
    archived = stashaway_goal("A", state: "ARCHIVED", name: "Simple SGD",
      transactions: [ stashaway_row("d1", "2026-01-05", "Deposit", 100), stashaway_row("w1", "2026-01-20", "Withdrawal", -50, operation_id: "op-7") ],
      nav: { "SGD" => stashaway_daily("2026-01-05", "2026-02-10") { |d| d < "2026-01-20" ? 100 : 50 } })
    active = stashaway_goal("B", name: "Simple SGD",
      transactions: [
        stashaway_row("d2", "2026-01-20", "Deposit", 50, operation_id: "op-1"),
        stashaway_row("d3", "2026-01-20", "Deposit", 50, operation_id: "op-7")
      ],
      nav: { "SGD" => stashaway_daily("2026-01-20", "2026-02-10") { 100 } })

    ids = stashaway_plan([ archived, active ]).entries.map(&:external_id)

    assert_includes ids, "tx:d2"
    assert_not_includes ids, "tx:d3"
    assert_not_includes ids, "tx:w1"
  end

  test "rows that are not completed or of an unknown type are left out" do
    goal = stashaway_goal("G1",
      transactions: [
        stashaway_row("d1", "2026-01-10", "Deposit", 100),
        stashaway_row("d2", "2026-01-11", "Deposit", 40, status: "Pending"),
        stashaway_row("z1", "2026-01-12", "Mystery", 5),
        stashaway_row("c1", "2026-01-13", "CashRebate", 1),
        stashaway_row("t1", "2026-01-14", "DividendTaxReimbursement", 0.5),
        stashaway_row("b1", "2026-01-15", "DividendRebate", 0.25)
      ],
      nav: { "SGD" => stashaway_daily("2026-01-10", "2026-01-31") { 101.75 } })

    plan = stashaway_plan([ goal ])

    assert_equal [ "Deposit", "Cash rebate", "Dividend tax reimbursement", "Dividend rebate" ], plan.entries.reject { |entry| entry.kind == :returns }.map(&:name)
    assert_match(/1 StashAway rows of unknown type "Mystery"/, plan.warnings.sole)
  end

  test "a closed portfolio never stored produces a warning and nothing else" do
    plan = stashaway_plan([ stashaway_goal("C", name: "FD 1", state: "CLOSED", unavailable: "closed", transactions: []) ])

    assert_not plan.applicable
    assert_empty plan.entries
    assert_nil plan.expected_balance
    assert_match(/no detail/, plan.warnings.first)
  end

  test "a closed portfolio is planned from its stored detail and worth nothing after its last valued day" do
    goal = stashaway_goal("C", name: "FD 1", state: "CLOSED", unavailable: "closed",
      transactions: [ stashaway_row("d1", "2026-01-10", "Deposit", 1000) ],
      nav: { "SGD" => stashaway_daily("2026-01-10", "2026-02-10") { |d| d < "2026-01-31" ? 1000 : 1010 } })

    plan = nil
    travel_to(Date.new(2026, 3, 1)) { plan = stashaway_plan([ goal ]) }

    assert plan.applicable
    assert_equal [
      "2026-01-10 Deposit -1000",
      "2026-01-31 Returns (month-end adjustment, 2026-01) -10",
      "2026-02-11 Withdrawal (portfolio closed) 1010"
    ], stashaway_plan_lines(plan.entries)
    assert_equal [ "tx:closed:C", :flow, "Withdrawal" ], plan.entries.last.to_h.values_at(:external_id, :kind, :activity_label)
    assert_equal [ Date.new(2026, 2, 11), 0, 0 ], [ plan.last_nav_date, plan.final_nav, plan.expected_balance ]
    assert_match(/detail stored last is used/, plan.warnings.sole)
  end

  test "a closing withdrawal waits while the account is only valued up to an earlier day" do
    closed = stashaway_goal("C", name: "Simple SGD", state: "CLOSED", unavailable: "closed",
      transactions: [ stashaway_row("d1", "2026-01-10", "Deposit", 100) ],
      nav: { "SGD" => stashaway_daily("2026-01-10", "2026-02-15") { 100 } })
    active = stashaway_goal("B", name: "Simple SGD",
      transactions: [ stashaway_row("d2", "2026-01-10", "Deposit", 200) ],
      nav: { "SGD" => stashaway_daily("2026-01-10", "2026-02-15") { 200 } })

    plan = stashaway_plan([ closed, active ])

    assert_equal Date.new(2026, 2, 15), plan.last_nav_date, "the open portfolio alone sets the latest value day"
    assert_equal [ "tx:closed:C" ], plan.pending.map(&:external_id)
    assert_equal 300, plan.expected_balance
  end

  test "a portfolio StashAway cannot find keeps its stored rows and value without capping the latest value day" do
    kept = stashaway_goal("A", name: "Simple SGD",
      transactions: [ stashaway_row("d1", "2026-01-05", "Deposit", 500) ],
      nav: { "SGD" => stashaway_daily("2026-01-05", "2026-02-20") { 500 } })
    missing = stashaway_goal("B", name: "Simple SGD", unavailable: "not found",
      transactions: [ stashaway_row("d2", "2026-01-10", "Deposit", 300) ],
      nav: { "SGD" => stashaway_daily("2026-01-10", "2026-02-10") { 300 } })

    plan = stashaway_plan([ kept, missing ])

    assert_equal [ "tx:d1", "tx:d2" ], plan.entries.map(&:external_id)
    assert_equal Date.new(2026, 2, 20), plan.last_nav_date
    assert_equal 800, plan.final_nav, "the last known value is carried forward"
    assert_match(/not found.*detail stored last is used/, plan.warnings.sole)
  end

  test "a plan without any value history is not applicable" do
    plan = stashaway_plan([ stashaway_goal("G1", transactions: [ stashaway_row("d1", "2026-01-10", "Deposit", 100) ]) ])

    assert_not plan.applicable
    assert_equal "no SGD value history for any portfolio", plan.reason
    assert_empty plan.entries
    assert_equal [ "nothing applied: no SGD value history for any portfolio" ], plan.warnings
  end

  test "a plan with an open portfolio whose rows have no value history is not applicable" do
    valued = stashaway_goal("A", name: "Simple SGD",
      transactions: [ stashaway_row("d1", "2026-01-05", "Deposit", 500) ],
      nav: { "SGD" => stashaway_daily("2026-01-05", "2026-01-31") { 500 } })
    unvalued = stashaway_goal("B", name: "New SGD", transactions: [ stashaway_row("d2", "2026-01-10", "Deposit", 300) ])

    plan = stashaway_plan([ valued, unvalued ])

    assert_not plan.applicable
    assert_equal "New SGD: no SGD value history", plan.reason
    assert_empty plan.entries
  end

  test "a portfolio whose value points are all unusable counts as unvalued" do
    valued = stashaway_goal("A", name: "Simple SGD",
      transactions: [ stashaway_row("d1", "2026-01-05", "Deposit", 500) ],
      nav: { "SGD" => stashaway_daily("2026-01-05", "2026-01-31") { 500 } })
    unusable = stashaway_goal("B", name: "New SGD",
      transactions: [ stashaway_row("d2", "2026-01-10", "Deposit", 300) ],
      nav: { "SGD" => [ { "date" => "not a date", "amount" => 300 }, { "date" => "2026-01-10T00:00:00.000Z", "amount" => "NaN" } ] })

    plan = stashaway_plan([ valued, unusable ])

    assert_not plan.applicable
    assert_equal "New SGD: no SGD value history", plan.reason
  end

  test "an append start without the account's balance before it is not applicable" do
    goal = stashaway_goal("G1",
      transactions: [ stashaway_row("d1", "2026-03-05", "Deposit", 200) ],
      nav: { "SGD" => stashaway_daily("2026-03-01", "2026-03-31") { 200 } })

    plan = stashaway_plan([ goal ], start: Date.new(2026, 3, 1), base: nil)

    assert_not plan.applicable
    assert_equal "the account's balance on 2026-02-28 is not known yet", plan.reason
  end

  test "protected rows count at their ledger figures, planned or not" do
    goal = stashaway_goal("G1",
      transactions: [
        stashaway_row("d1", "2026-01-10", "Deposit", 1000),
        stashaway_row("f1", "2026-02-05", "Fee", -1, description: "2026-01")
      ],
      nav: { "SGD" => stashaway_daily("2026-01-10", "2026-02-15") { |d| d <= "2026-01-30" ? 1000 : (d == "2026-01-31" ? 1010 : 1020) } })
    protected = [
      stashaway_protected("tx:d1", "2026-01-10", -990), # the user changed the deposit
      stashaway_protected("tx:e9", "2026-02-08", -2.5)  # a row StashAway no longer sends, kept
    ]

    plan = stashaway_plan([ goal ], protected: protected)

    assert_equal [ "tx:d1", "ret:2026-01", "tx:f1", "ret:2026-02" ], plan.entries.map(&:external_id)
    assert_equal BigDecimal("-1000"), plan.entries.first.amount, "the plan still asks for StashAway's figure"
    assert_equal [ BigDecimal("-20"), BigDecimal("-8.5") ], plan.entries.select { |entry| entry.kind == :returns }.map(&:amount)
  end

  test "a returns row the user froze keeps its figure and the next month's absorbs the rest" do
    goal = stashaway_goal("G1",
      transactions: [ stashaway_row("d1", "2026-01-10", "Deposit", 1000) ],
      nav: { "SGD" => stashaway_daily("2026-01-10", "2026-02-15") { |d| d <= "2026-01-30" ? 1000 : (d == "2026-01-31" ? 1010 : 1020) } })

    plan = stashaway_plan([ goal ], protected: [ stashaway_protected("ret:2026-01", "2026-01-31", -4) ])

    assert_equal [ "2026-01-10 Deposit -1000", "2026-02-15 Returns (month-to-date adjustment, 2026-02) -16" ], stashaway_plan_lines(plan.entries)
    assert_equal 1020, 4 - plan.entries.sum(&:amount)
  end

  test "rounds half away from zero without float noise" do
    assert_equal BigDecimal("0.3"), StashawayAccount::EntryPlan.round2(0.1 + 0.2)
    assert_equal BigDecimal("-1.01"), StashawayAccount::EntryPlan.round2(BigDecimal("-1.005"))
    assert_equal BigDecimal("1.01"), StashawayAccount::EntryPlan.round2(BigDecimal("1.005"))
  end

  test "an append start measures its first month from the account's own balance" do
    goal = stashaway_goal("G1",
      transactions: [
        stashaway_row("d0", "2026-01-10", "Deposit", 1000),
        stashaway_row("d1", "2026-03-05", "Deposit", 200),
        stashaway_row("f1", "2026-03-06", "Fee", -2, description: "2026-02")
      ],
      # StashAway's own value on Feb 28 is 1100, but the statement-based
      # balance that day is 1093.22; March must still close on 1350.
      nav: { "SGD" => stashaway_daily("2026-01-10", "2026-03-31") { |d| d < "2026-03-01" ? 1100 : 1350 } })

    plan = stashaway_plan([ goal ], start: Date.new(2026, 3, 1), base: BigDecimal("1093.22"))

    assert_equal [
      "2026-03-05 Deposit -200",
      "2026-03-06 Management fee (Feb 2026) 2",
      "2026-03-31 Returns (month-end adjustment, 2026-03) -58.78"
    ], stashaway_plan_lines(plan.entries)
    assert_equal 1350, BigDecimal("1093.22") - plan.entries.sum(&:amount)
    assert_equal 1350, plan.expected_balance
  end

  test "a start after the latest value day plans nothing and expects the base" do
    goal = stashaway_goal("G1",
      transactions: [ stashaway_row("d1", "2026-01-10", "Deposit", 10) ],
      nav: { "SGD" => stashaway_daily("2026-01-10", "2026-01-20") { 10 } })

    plan = stashaway_plan([ goal ], start: Date.new(2026, 1, 25), base: BigDecimal("9.5"))

    assert_empty plan.entries
    assert_equal BigDecimal("9.5"), plan.expected_balance
  end

  test "values are planned in the account currency" do
    goal = stashaway_goal("G1",
      transactions: [ stashaway_row("d1", "2026-01-10", "Deposit", 1350) ],
      nav: {
        "SGD" => stashaway_daily("2026-01-10", "2026-01-31") { 1350 },
        "USD" => stashaway_daily("2026-01-10", "2026-01-31") { 1000 }
      })

    plan = stashaway_plan([ goal ], currency: "USD")

    assert_equal [ "Deposit (SGD 1350.00 @ 0.7407)" ], plan.entries.reject { |entry| entry.kind == :returns }.map(&:name)
    assert_equal 1000, plan.expected_balance
    assert_equal 1000, -plan.entries.sum(&:amount)
  end
end
