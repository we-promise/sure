require "test_helper"

# Pure-Ruby solver tests. No ActiveRecord: the planner is fed plain hashes and
# integer-cent BigDecimals, so the math is exercised exactly as it will run.
class PaycheckFlowPlannerTest < ActiveSupport::TestCase
  P1 = "partner-1".freeze
  P2 = "partner-2".freeze

  def planner(month:, incomes:, allocations: [], obligations: {}, partners: [ P1, P2 ], distribution: "equal_split")
    PaycheckFlowPlanner.new(
      month: month,
      incomes: incomes,
      allocations: allocations,
      obligations_by_account: obligations,
      partners: partners,
      leftover_distribution: distribution
    ).plan
  end

  def income(id:, owner_id:, amounts:)
    n = amounts.size
    { id: id, owner_id: owner_id,
      occurrences: amounts.map.with_index do |cents, i|
        day = n.zero? ? 6 : 1 + (i * 30) / n
        { date: Date.new(2026, 11, day), amount_cents: BigDecimal(cents) }
      end }
  end

  def edge(income_id:, account_id:, mode:, value_cents: nil, value_percent: nil)
    { income_id: income_id, account_id: account_id, mode: mode,
      value_cents: value_cents, value_percent: value_percent }
  end

  # 1. A 90/10 income split is equalized under equal_split: the pooled leftover
  # is credited 1/N per partner, so the smaller earner is not left with less.
  test "90/10 income split equalized under equal_split" do
    a = income(id: "A", owner_id: P1, amounts: [ 90_000 ]) # 900.00
    b = income(id: "B", owner_id: P2, amounts: [ 10_000 ]) # 100.00
    plan = planner(
      month: Date.new(2026, 11, 1),
      incomes: [ a, b ],
      allocations: [
        edge(income_id: "A", account_id: "accA", mode: "leftover"),
        edge(income_id: "B", account_id: "accB", mode: "leftover")
      ],
      distribution: "equal_split"
    )

    attr = plan[:leftover_attribution]
    assert_equal "equal_split", attr[:distribution]
    assert_equal "1000.00", attr[:pooled_month] # 900 + 100
    p1, p2 = attr[:by_partner]
    assert_equal "0.5000", p1[:weight]
    assert_equal "0.5000", p2[:weight]
    # Equal credit despite the 9x income gap.
    assert_equal "500.00", p1[:fun_money_month]
    assert_equal "500.00", p2[:fun_money_month]
    assert_equal "500.00", attr[:pooled_per_paycheck] # 1000 / 2 paychecks
  end

  # 2. income_ratio attributes by each partner's share of total income.
  test "income_ratio attribution math" do
    a = income(id: "A", owner_id: P1, amounts: [ 90_000 ])
    b = income(id: "B", owner_id: P2, amounts: [ 10_000 ])
    plan = planner(
      month: Date.new(2026, 11, 1),
      incomes: [ a, b ],
      allocations: [
        edge(income_id: "A", account_id: "accA", mode: "leftover"),
        edge(income_id: "B", account_id: "accB", mode: "leftover")
      ],
      distribution: "income_ratio"
    )

    attr = plan[:leftover_attribution]
    p1, p2 = attr[:by_partner]
    assert_equal "0.9000", p1[:weight] # 900 / 1000
    assert_equal "0.1000", p2[:weight] # 100 / 1000
    assert_equal "900.00", p1[:fun_money_month]
    assert_equal "100.00", p2[:fun_money_month]
  end

  # 3. Biweekly reality: the same monthly obligation prorates over 2 paychecks
  # in a 2-paycheck month and 3 in a 3-paycheck month.
  test "obligations prorate over 2 vs 3 paychecks" do
    # 2 paychecks.
    two = income(id: "A", owner_id: P1, amounts: [ 50_000, 50_000 ])
    plan_two = planner(
      month: Date.new(2026, 11, 1),
      incomes: [ two ],
      allocations: [
        edge(income_id: "A", account_id: "accObl", mode: "required"),
        edge(income_id: "A", account_id: "accFun", mode: "leftover")
      ],
      obligations: { "accObl" => BigDecimal(60_000) }, # 600.00/month
      partners: [ P1 ]
    )
    # 3 paychecks.
    three = income(id: "A", owner_id: P1, amounts: [ 40_000, 40_000, 40_000 ])
    plan_three = planner(
      month: Date.new(2026, 11, 1),
      incomes: [ three ],
      allocations: [
        edge(income_id: "A", account_id: "accObl", mode: "required"),
        edge(income_id: "A", account_id: "accFun", mode: "leftover")
      ],
      obligations: { "accObl" => BigDecimal(60_000) },
      partners: [ P1 ]
    )

    acc2 = plan_two[:accounts].find { |x| x[:id] == "accObl" }
    acc3 = plan_three[:accounts].find { |x| x[:id] == "accObl" }
    assert_equal "600.00", acc2[:required_month]
    assert_equal "600.00", acc3[:required_month]
    assert_equal "300.00", acc2[:required_per_paycheck] # 600 / 2
    assert_equal "200.00", acc3[:required_per_paycheck] # 600 / 3
    assert_equal 2, plan_two[:total_paychecks]
    assert_equal 3, plan_three[:total_paychecks]

    # Summing the per-paycheck required over the month lands exactly on the
    # monthly total in both cases (frequencies partition the paychecks).
    total_two = plan_two[:paychecks].sum { |p| BigDecimal(p[:by_account]["accObl"]) }
    total_three = plan_three[:paychecks].sum { |p| BigDecimal(p[:by_account]["accObl"]) }
    assert_equal BigDecimal("600.00"), total_two
    assert_equal BigDecimal("600.00"), total_three
  end

  # 4. Percent rounding: the half-cent is rounded up into the percent edge and
  # the remainder lands in leftover, so the two sum exactly to the income.
  test "percent rounding remainder lands in leftover" do
    a = income(id: "A", owner_id: P1, amounts: [ 9_999 ]) # 99.99
    plan = planner(
      month: Date.new(2026, 11, 1),
      incomes: [ a ],
      allocations: [
        edge(income_id: "A", account_id: "accPct", mode: "percent", value_percent: BigDecimal(0.5)),
        edge(income_id: "A", account_id: "accLeft", mode: "leftover")
      ],
      partners: [ P1 ]
    )

    paycheck = plan[:paychecks].first
    pct = paycheck[:allocations].find { |x| x[:account_id] == "accPct" }[:amount]
    left = paycheck[:allocations].find { |x| x[:account_id] == "accLeft" }
    # 99.99 * 0.5 = 49.995 -> rounds half-up to 50.00; remainder 49.99.
    assert_equal "50.00", pct
    assert_equal "49.99", left[:amount]
    assert_equal BigDecimal("99.99"), BigDecimal(pct) + BigDecimal(left[:amount])
  end

  # 5. Multiple income streams can fund the same account.
  test "multiple income streams into one account" do
    a = income(id: "A", owner_id: P1, amounts: [ 50_000 ])
    b = income(id: "B", owner_id: P2, amounts: [ 30_000 ])
    plan = planner(
      month: Date.new(2026, 11, 1),
      incomes: [ a, b ],
      allocations: [
        edge(income_id: "A", account_id: "accShared", mode: "specific", value_cents: 10_000),
        edge(income_id: "A", account_id: "accFunA", mode: "leftover"),
        edge(income_id: "B", account_id: "accShared", mode: "specific", value_cents: 5_000),
        edge(income_id: "B", account_id: "accFunB", mode: "leftover")
      ]
    )

    shared = plan[:accounts].find { |x| x[:id] == "accShared" }
    assert_equal "150.00", shared[:total_in_month] # 100 + 50
    paycheck = plan[:paychecks].first
    assert_equal "150.00", paycheck[:by_account]["accShared"]
  end

  # 6. A required edge on an account with no obligations resolves to 0.
  test "required mode on a zero-obligation account is 0" do
    a = income(id: "A", owner_id: P1, amounts: [ 50_000 ])
    plan = planner(
      month: Date.new(2026, 11, 1),
      incomes: [ a ],
      allocations: [
        edge(income_id: "A", account_id: "accReq", mode: "required"),
        edge(income_id: "A", account_id: "accFun", mode: "leftover")
      ],
      obligations: {},
      partners: [ P1 ]
    )

    req = plan[:paychecks].first[:allocations].find { |x| x[:account_id] == "accReq" }
    assert_equal "0.00", req[:amount]
    assert_equal "0.00", plan[:paychecks].first[:by_account]["accReq"]
    # The whole paycheck falls through to leftover.
    assert_equal "500.00", plan[:paychecks].first[:by_account]["accFun"]
  end

  # 7. When required + specific outrun the income, the leftover goes negative
  # and a shortfall is flagged.
  test "shortfall when required plus specific exceeds income" do
    a = income(id: "A", owner_id: P1, amounts: [ 10_000 ]) # 100.00
    plan = planner(
      month: Date.new(2026, 11, 1),
      incomes: [ a ],
      allocations: [
        edge(income_id: "A", account_id: "accReq", mode: "required"),
        edge(income_id: "A", account_id: "accSpec", mode: "specific", value_cents: 5_000),
        edge(income_id: "A", account_id: "accLeft", mode: "leftover")
      ],
      obligations: { "accReq" => BigDecimal(12_000) }, # 120.00 > 100.00
      partners: [ P1 ]
    )

    assert_equal 1, plan[:shortfalls].size
    assert_equal "A", plan[:shortfalls].first[:income_series_id]
    assert_equal "70.00", plan[:shortfalls].first[:gap_month] # (120+50) - 100
    left = plan[:paychecks].first[:allocations].find { |x| x[:account_id] == "accLeft" }
    assert_equal "-70.00", left[:amount]
    assert_equal true, left[:shortfall]
  end

  # 8. specific + percent + leftover mixed on one stream.
  test "specific plus percent plus leftover mixed" do
    a = income(id: "A", owner_id: P1, amounts: [ 100_000 ]) # 1000.00
    plan = planner(
      month: Date.new(2026, 11, 1),
      incomes: [ a ],
      allocations: [
        edge(income_id: "A", account_id: "accSpec", mode: "specific", value_cents: 10_000),
        edge(income_id: "A", account_id: "accPct", mode: "percent", value_percent: BigDecimal(0.10)),
        edge(income_id: "A", account_id: "accLeft", mode: "leftover")
      ],
      partners: [ P1 ]
    )

    paycheck = plan[:paychecks].first
    assert_equal "100.00", paycheck[:by_account]["accSpec"]
    assert_equal "100.00", paycheck[:by_account]["accPct"] # 1000 * 0.10
    assert_equal "800.00", paycheck[:by_account]["accLeft"]
    assert_equal "1000.00", paycheck[:total_income]
  end

  # 9. Suggested fix: the partner above target with exactly one percent edge
  # gets a closed-form shift so their leftover lands on the mean.
  test "suggested fix shifts the over-target partner's percent edge" do
    a = income(id: "A", owner_id: P1, amounts: [ 100_000 ]) # 1000.00, 10% -> leftover 900
    b = income(id: "B", owner_id: P2, amounts: [ 50_000 ]) # 500.00, 50% -> leftover 250
    plan = planner(
      month: Date.new(2026, 11, 1),
      incomes: [ a, b ],
      allocations: [
        edge(income_id: "A", account_id: "accPctA", mode: "percent", value_percent: BigDecimal(0.10)),
        edge(income_id: "A", account_id: "accLeftA", mode: "leftover"),
        edge(income_id: "B", account_id: "accPctB", mode: "percent", value_percent: BigDecimal(0.50)),
        edge(income_id: "B", account_id: "accLeftB", mode: "leftover")
      ]
    )

    fix = plan[:suggested_fix]
    refute_nil fix
    assert_equal P1, fix[:user_id] # P1 leftover 900 > P2 250
    assert_equal "A", fix[:income_series_id]
    assert_equal "0.1000", fix[:current_percent]
    # target = (900 + 250)/2 = 575; delta = +325; shift = 325/1000 = 0.325.
    assert_equal "0.4250", fix[:suggested_percent]
    assert_equal "575.00", fix[:new_leftover_month]

    delta = plan[:delta]
    assert_equal "575.00", delta[:target_month]
    assert_equal "650.00", delta[:spread_month] # 900 - 250
  end

  # 10. No paychecks in the month: the plan is still valid, nothing applies.
  test "a month with no paychecks produces an empty but valid plan" do
    a = income(id: "A", owner_id: P1, amounts: [])
    plan = planner(
      month: Date.new(2026, 11, 1),
      incomes: [ a ],
      allocations: [ edge(income_id: "A", account_id: "accReq", mode: "required") ],
      obligations: { "accReq" => BigDecimal(60_000) },
      partners: [ P1 ]
    )

    assert_equal 0, plan[:total_paychecks]
    assert_equal [], plan[:paychecks]
    # With no paychecks the per-paycheck required stays the monthly total but
    # is never applied; no shortfall is claimed.
    assert_equal "600.00", plan[:accounts].first[:required_per_paycheck]
    assert_equal [], plan[:shortfalls]
  end

  # Round 11 issue 8 (regression guard): the PR#1 plan() path is
  # BYTE-IDENTICAL for a family with sub-accounts + fan-out configured —
  # inputs_for carries no sub-account keys and the PR#1 resolver ignores
  # them (they exist for plan_graph only).
  test "plan() output is byte-identical with sub-accounts and fan-out configured" do
    a = income(id: "A", owner_id: P1, amounts: [ 90_000, 90_000 ])
    b = income(id: "B", owner_id: P2, amounts: [ 10_000, 10_000 ])
    edges = [
      edge(income_id: "A", account_id: "accA", mode: "specific", value_cents: BigDecimal(50_000)),
      edge(income_id: "A", account_id: "leftover", mode: "leftover"),
      edge(income_id: "B", account_id: "accB", mode: "leftover")
    ]

    plain = PaycheckFlowPlanner.new(
      month: Date.new(2026, 11, 1),
      incomes: [ a, b ],
      allocations: edges,
      obligations_by_account: { "accA" => BigDecimal(20_000), "accB" => BigDecimal(15_000) },
      partners: [ P1, P2 ],
      leftover_distribution: "income_ratio"
    ).plan

    with_links = PaycheckFlowPlanner.new(
      month: Date.new(2026, 11, 1),
      incomes: [ a, b ],
      allocations: edges,
      obligations_by_account: { "accA" => BigDecimal(20_000), "accB" => BigDecimal(15_000) },
      partners: [ P1, P2 ],
      leftover_distribution: "income_ratio",
      sub_account_links: { "sub" => "accA", "sub2" => "accB" },
      auto_transfer_targets: { "accA" => [ "sub", "sub2" ], "accB" => [ "sub" ] },
      account_names: { "accA" => "Checking", "accB" => "Savings", "sub" => "Bucket" }
    ).plan

    assert_equal plain.to_json, with_links.to_json,
      "the PR#1 plan() output must be byte-identical with fan-out inputs present"
  end
end
