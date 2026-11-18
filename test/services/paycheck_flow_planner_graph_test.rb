require "test_helper"

# Pure-Ruby tests for plan_graph (M2 PR#2b): the planning diagram's fixed
# bank-level resolution order, over-plan flags, unallocated remainders,
# limit warnings, and the draft merge. No ActiveRecord — same style as the
# PR#1 solver tests.
class PaycheckFlowPlannerGraphTest < ActiveSupport::TestCase
  P1 = "partner-1".freeze
  P2 = "partner-2".freeze

  def graph(month:, incomes:, allocations: [], obligations: {}, plan_allocations: [], required_amounts: {}, plan_max_links: {}, plan_roles: {}, auto_transfers: {}, plan_ordered: {}, linked_bank_counts: {}, recommendations: [], partners: [ P1 ], sub_account_links: {}, auto_transfer_targets: {}, account_names: {}, account_last4s: {}, account_bank_logos: {}, bank_logo_keywords: [], bank_logos: {}, categories: {}, draft: nil)
    PaycheckFlowPlanner.new(
      month: month,
      incomes: incomes,
      allocations: allocations,
      obligations_by_account: obligations,
      partners: partners,
      leftover_distribution: "income_ratio",
      currency: "USD",
      plan_allocations: plan_allocations,
      required_amounts: required_amounts,
      plan_max_links: plan_max_links,
      plan_roles: plan_roles,
      auto_transfers: auto_transfers,
      plan_ordered: plan_ordered,
      linked_bank_counts: linked_bank_counts,
      recommendations: recommendations,
      sub_account_links: sub_account_links,
      auto_transfer_targets: auto_transfer_targets,
      account_names: account_names,
      account_last4s: account_last4s,
      account_bank_logos: account_bank_logos,
      bank_logo_keywords: bank_logo_keywords,
      bank_logos: bank_logos,
      categories: categories,
      draft: draft
    ).plan_graph
  end

  def income(id:, owner_id: P1, amounts: [], name: "Paycheck")
    { id: id, name: name, owner_id: owner_id,
      occurrences: amounts.map.with_index do |cents, i|
        day = amounts.size.zero? ? 6 : 1 + (i * 30) / amounts.size
        { date: Date.new(2026, 11, day), amount_cents: BigDecimal(cents) }
      end }
  end

  def edge(income_id:, account_id:, mode:, value_cents: nil, value_percent: nil)
    { income_id: income_id, account_id: account_id, mode: mode,
      value_cents: value_cents, value_percent: value_percent }
  end

  def alloc(id:, account_id:, name: "Alloc", kind: "bill", mode: "required", value_cents: nil, value_percent: nil, recurring_transaction_id: nil, auto_transfer: false, category_id: nil)
    { id: id, account_id: account_id, name: name, kind: kind, mode: mode,
      value_cents: value_cents, value_percent: value_percent,
      cadence: "monthly", recurring_transaction_id: recurring_transaction_id,
      auto_transfer: auto_transfer, category_id: category_id }
  end

  # 1. The owner's example: income 1000, bills 800 (required), fun 300 hard
  # -> bills paid first, fun gets 200 and the 100 gap is the over-plan flag,
  # RED on the fun money allocation.
  test "bills first: fun money short becomes the over-plan flag" do
    g = graph(
      month: Date.new(2026, 11, 1),
      incomes: [ income(id: "A", amounts: [ 100_000 ]) ],
      allocations: [ edge(income_id: "A", account_id: "chk", mode: "leftover") ],
      plan_allocations: [
        alloc(id: "b1", account_id: "chk", name: "Bills", kind: "bill", mode: "required", value_cents: BigDecimal(80_000)),
        alloc(id: "f1", account_id: "chk", name: "Fun", kind: "fun_money", mode: "specific", value_cents: BigDecimal(30_000))
      ]
    )

    bills = g[:allocations].find { |a| a[:id] == "b1" }
    fun = g[:allocations].find { |a| a[:id] == "f1" }
    assert_equal "800.00", bills[:wanted_month]
    assert_equal "800.00", bills[:got_month]
    assert_equal "ok", bills[:status]
    assert_equal false, bills[:over_planned]
    assert_equal "300.00", fun[:wanted_month]
    assert_equal "200.00", fun[:got_month]
    assert_equal "100.00", fun[:shortfall_month]
    assert_equal "partly", fun[:status]
    assert_equal true, fun[:over_planned]

    flag = g[:over_plans].find { |f| f[:income_id] == "A" }
    assert_equal "fun_money", flag[:target]
    assert_equal "f1", flag[:target_id]
    assert_equal "100.00", flag[:shortfall_month]
    assert_equal "100.00", g[:incomes].find { |i| i[:id] == "A" }[:over_plan][:shortfall_month]

    chk = g[:banks].find { |b| b[:id] == "chk" }
    assert_equal "1000.00", chk[:inflow_month]
    assert_equal "0.00", chk[:surplus_month]
    assert_equal "1000.00", chk[:inflow].find { |band| band[:income_id] == "A" }[:amount]
    assert_equal "0.00", g[:incomes].find { |i| i[:id] == "A" }[:unallocated_month]
  end

  # 2. Same gap with NO fun money planned: the flag lands on the
  # surplus/savings line (target "surplus", no allocation id).
  test "over-plan without fun money targets the surplus line" do
    g = graph(
      month: Date.new(2026, 11, 1),
      incomes: [ income(id: "A", amounts: [ 100_000 ]) ],
      allocations: [ edge(income_id: "A", account_id: "chk", mode: "leftover") ],
      plan_allocations: [
        alloc(id: "b1", account_id: "chk", name: "Bills", kind: "bill", mode: "required", value_cents: BigDecimal(80_000)),
        alloc(id: "s1", account_id: "chk", name: "Savings", kind: "savings", mode: "specific", value_cents: BigDecimal(30_000))
      ]
    )

    flag = g[:over_plans].find { |f| f[:income_id] == "A" }
    assert_equal "surplus", flag[:target]
    assert_nil flag[:target_id]
    assert_equal "100.00", flag[:shortfall_month]
    assert_equal false, g[:allocations].find { |a| a[:id] == "s1" }[:over_planned]
  end

  # 3. Percent mode takes its share of the bank's leftover pool — the
  # residual after required and specific, not the bank's inflow.
  test "percent mode resolves off the post-bill pool" do
    g = graph(
      month: Date.new(2026, 11, 1),
      incomes: [ income(id: "A", amounts: [ 100_000 ]) ],
      allocations: [
        edge(income_id: "A", account_id: "X", mode: "specific", value_cents: BigDecimal(40_000)),
        edge(income_id: "A", account_id: "Y", mode: "leftover")
      ],
      plan_allocations: [
        alloc(id: "b1", account_id: "Y", name: "Bills", mode: "required", value_cents: BigDecimal(20_000)),
        alloc(id: "s1", account_id: "Y", name: "Savings", kind: "savings", mode: "specific", value_cents: BigDecimal(10_000)),
        alloc(id: "p1", account_id: "Y", name: "Pct", kind: "savings", mode: "percent", value_percent: BigDecimal("0.5"))
      ]
    )

    # Y inflow 600; pool after bills 400; after specific 300; 50% -> 150.
    pct = g[:allocations].find { |a| a[:id] == "p1" }
    assert_equal "150.00", pct[:got_month]
    assert_equal "ok", pct[:status]
    y = g[:banks].find { |b| b[:id] == "Y" }
    assert_equal "150.00", y[:surplus_month] # 600 - 200 - 100 - 150
    x = g[:banks].find { |b| b[:id] == "X" }
    assert_equal "400.00", x[:surplus_month]
    assert_equal [], g[:over_plans]
  end

  # 4. Leftover mode splits the bank's final residual equally among the
  # leftover allocations; the last share absorbs the remainder exactly.
  test "leftover mode splits the residual equally" do
    two = graph(
      month: Date.new(2026, 11, 1),
      incomes: [ income(id: "A", amounts: [ 100_001 ]) ],
      allocations: [ edge(income_id: "A", account_id: "L", mode: "leftover") ],
      plan_allocations: [
        alloc(id: "l1", account_id: "L", kind: "savings", mode: "leftover"),
        alloc(id: "l2", account_id: "L", kind: "savings", mode: "leftover")
      ]
    )
    assert_equal "500.00", two[:allocations].find { |a| a[:id] == "l1" }[:got_month]
    assert_equal "500.01", two[:allocations].find { |a| a[:id] == "l2" }[:got_month]
    assert_equal "0.00", two[:banks].find { |b| b[:id] == "L" }[:surplus_month]

    three = graph(
      month: Date.new(2026, 11, 1),
      incomes: [ income(id: "A", amounts: [ 100_003 ]) ],
      allocations: [ edge(income_id: "A", account_id: "L", mode: "leftover") ],
      plan_allocations: [
        alloc(id: "l1", account_id: "L", kind: "savings", mode: "leftover"),
        alloc(id: "l2", account_id: "L", kind: "savings", mode: "leftover"),
        alloc(id: "l3", account_id: "L", kind: "savings", mode: "leftover")
      ]
    )
    gots = three[:allocations].map { |a| a[:id] }
    assert_equal "333.34", three[:allocations].find { |a| a[:id] == "l1" }[:got_month]
    assert_equal "333.34", three[:allocations].find { |a| a[:id] == "l2" }[:got_month]
    assert_equal "333.35", three[:allocations].find { |a| a[:id] == "l3" }[:got_month]
    assert_equal %w[l1 l2 l3], gots
  end

  # 5. Per-income unallocated remainder: money that never flows to a linked
  # bank (no leftover edge) is the hatched "Un-Allocated" band.
  test "income not flowing to any bank shows the unallocated remainder" do
    g = graph(
      month: Date.new(2026, 11, 1),
      incomes: [ income(id: "A", amounts: [ 50_000 ]) ],
      allocations: [ edge(income_id: "A", account_id: "S", mode: "specific", value_cents: BigDecimal(10_000)) ]
    )

    a = g[:incomes].find { |i| i[:id] == "A" }
    assert_equal "400.00", a[:unallocated_month]
    assert_equal [ "400.00" ], a[:unallocated].map { |row| row[:amount] }
    s = g[:banks].find { |b| b[:id] == "S" }
    assert_equal "100.00", s[:inflow_month]
    assert_equal [], g[:over_plans]
  end

  # 6. Link-limit warnings: linked bank count above plan_max_account_links
  # flags the income; at or under the limit nothing happens. A declared but
  # silent paycheck (no occurrences) still shows its warning.
  test "limit warnings on linked count above the income limit" do
    g = graph(
      month: Date.new(2026, 11, 1),
      incomes: [ income(id: "A", amounts: [ 50_000 ]), income(id: "B") ],
      allocations: [],
      plan_max_links: { "A" => 2, "B" => 1 },
      linked_bank_counts: { "A" => 3, "B" => 2 }
    )

    a = g[:incomes].find { |i| i[:id] == "A" }
    b = g[:incomes].find { |i| i[:id] == "B" }
    assert_equal({ linked_count: 3, limit: 2 }, a[:limit_warning])
    assert_equal({ linked_count: 2, limit: 1 }, b[:limit_warning]) # silent paycheck
    assert_equal "0.00", b[:total_month]
    assert_equal %w[A B], g[:limit_warnings].map { |w| w[:income_id] }

    at_limit = graph(
      month: Date.new(2026, 11, 1),
      incomes: [ income(id: "A", amounts: [ 50_000 ]) ],
      plan_max_links: { "A" => 3 },
      linked_bank_counts: { "A" => 3 }
    )
    assert_nil at_limit[:incomes].first[:limit_warning]
    assert_equal [], at_limit[:limit_warnings]
  end

  # 7. Short bank: bills take everything they can (best-effort, status caps
  # at partly — bills are never the over-plan flag target), the non-bill item
  # goes to 0 and reads "over"; the flag still lands on the surplus line.
  test "short bank caps bills at partly and flags the surplus" do
    g = graph(
      month: Date.new(2026, 11, 1),
      incomes: [ income(id: "A", amounts: [ 50_000 ]) ],
      allocations: [ edge(income_id: "A", account_id: "B", mode: "leftover") ],
      plan_allocations: [
        alloc(id: "b1", account_id: "B", name: "Bills", kind: "bill", mode: "required", value_cents: BigDecimal(80_000)),
        alloc(id: "s1", account_id: "B", name: "Savings", kind: "savings", mode: "specific", value_cents: BigDecimal(5_000))
      ]
    )

    bills = g[:allocations].find { |a| a[:id] == "b1" }
    savings = g[:allocations].find { |a| a[:id] == "s1" }
    assert_equal "500.00", bills[:got_month]
    assert_equal "300.00", bills[:shortfall_month]
    assert_equal "partly", bills[:status]
    assert_equal "0.00", savings[:got_month]
    assert_equal "over", savings[:status]
    assert_equal "0.00", g[:banks].find { |b| b[:id] == "B" }[:surplus_month] # bills took it all
    flag = g[:over_plans].find { |f| f[:income_id] == "A" }
    assert_equal "surplus", flag[:target]
    assert_equal "350.00", flag[:shortfall_month] # (800+50) - 500
  end

  # 8. Draft merge: a draft plan_allocations set replaces the saved rows
  # wholesale; a draft edges set replaces the saved income->bank edges.
  test "draft rows merge over the saved state" do
    saved_alloc = alloc(id: "a1", account_id: "chk", name: "Bills", value_cents: BigDecimal(50_000))
    draft_allocs = [
      alloc(id: "a1", account_id: "chk", name: "Bills", value_cents: BigDecimal(90_000)),
      alloc(id: "a2", account_id: "chk", name: "Fun", kind: "fun_money", mode: "specific", value_cents: BigDecimal(10_000))
    ]
    g = graph(
      month: Date.new(2026, 11, 1),
      incomes: [ income(id: "A", amounts: [ 100_000 ]) ],
      allocations: [ edge(income_id: "A", account_id: "chk", mode: "leftover") ],
      plan_allocations: [ saved_alloc ],
      draft: { plan_allocations: draft_allocs }
    )

    assert_equal %w[a1 a2], g[:allocations].map { |a| a[:id] }
    a1 = g[:allocations].find { |a| a[:id] == "a1" }
    assert_equal "900.00", a1[:wanted_month] # draft value won
    assert_equal "Bills", a1[:name]

    # Edge draft: the saved leftover edge is replaced by a specific edge.
    g2 = graph(
      month: Date.new(2026, 11, 1),
      incomes: [ income(id: "A", amounts: [ 100_000 ]) ],
      allocations: [ edge(income_id: "A", account_id: "chk", mode: "leftover") ],
      draft: { allocations: [ edge(income_id: "A", account_id: "other", mode: "specific", value_cents: BigDecimal(30_000)) ] }
    )
    band = g2[:banks].find { |b| b[:id] == "other" }
    assert_equal "300.00", band[:inflow_month]
    assert_nil g2[:banks].find { |b| b[:id] == "chk" }
  end

  # 9. Recommendations pass through untouched; account roles and
  # auto-transfers surface on the bank nodes.
  test "recommendations and bank roles pass through" do
    recs = [
      { type: "recurring_transaction", recurring_transaction_id: "rt9", name: "Netflix",
        kind: "bill", cadence: "monthly", amount: BigDecimal("15.99"), account_id: "chk" }
    ]
    g = graph(
      month: Date.new(2026, 11, 1),
      incomes: [ income(id: "A", amounts: [ 50_000 ]) ],
      plan_roles: { "cc" => "credit_card_payoff" },
      auto_transfers: { "chk" => "cc" },
      recommendations: recs
    )

    assert_equal recs, g[:recommendations]
    cc = g[:banks].find { |b| b[:id] == "cc" }
    assert_equal "credit_card_payoff", cc[:plan_role]
    assert_equal "cc", g[:banks].find { |b| b[:id] == "chk" }[:auto_transfer_to_account_id]
  end

  # 10. Required mode with a linked recurring transaction and no explicit
  # value: the amount is the RT's monthly equivalent, prorated over the
  # month's paychecks.
  test "required allocation resolves from the linked RT monthly equivalent" do
    g = graph(
      month: Date.new(2026, 11, 1),
      incomes: [ income(id: "A", amounts: [ 10_000, 10_000, 10_000 ]) ],
      allocations: [ edge(income_id: "A", account_id: "chk", mode: "leftover") ],
      plan_allocations: [
        alloc(id: "b1", account_id: "chk", name: "Netflix", recurring_transaction_id: "rt1")
      ],
      required_amounts: { "rt1" => BigDecimal(30_000) } # 300.00/month
    )

    b1 = g[:allocations].find { |a| a[:id] == "b1" }
    assert_equal "300.00", b1[:wanted_month]
    assert_equal 3, b1[:per_paycheck].size
    assert_equal "100.00", b1[:per_paycheck].first[:wanted] # 300 / 3
    assert_equal "ok", b1[:status]
    assert_equal "300.00", b1[:got_month]
  end

  # 11. Compat: with no plan allocations the graph keeps the PR#1 edge
  # resolution (required base from the raw recurring obligations) and every
  # bank's surplus is just its inflow; the old report is unchanged.
  test "empty allocation set keeps the PR#1 numbers" do
    g = graph(
      month: Date.new(2026, 11, 1),
      incomes: [ income(id: "A", amounts: [ 10_000 ]) ],
      allocations: [
        edge(income_id: "A", account_id: "accReq", mode: "required"),
        edge(income_id: "A", account_id: "accSpec", mode: "specific", value_cents: BigDecimal(5_000)),
        edge(income_id: "A", account_id: "accLeft", mode: "leftover")
      ],
      obligations: { "accReq" => BigDecimal(12_000) }
    )

    req = g[:banks].find { |b| b[:id] == "accReq" }
    spec = g[:banks].find { |b| b[:id] == "accSpec" }
    left = g[:banks].find { |b| b[:id] == "accLeft" }
    assert_equal "120.00", req[:inflow_month] # 120.00/month required edge
    assert_equal "50.00", spec[:inflow_month]
    assert_equal "-70.00", left[:inflow_month] # 100 - 120 - 50
    assert_equal "120.00", req[:surplus_month] # no allocations -> surplus = inflow
    assert_equal "-70.00", left[:surplus_month]
    assert_equal [], g[:over_plans]

    # The old entry point is untouched.
    plan = PaycheckFlowPlanner.new(
      month: Date.new(2026, 11, 1),
      incomes: [ income(id: "A", amounts: [ 10_000 ]) ],
      allocations: [
        edge(income_id: "A", account_id: "accReq", mode: "required"),
        edge(income_id: "A", account_id: "accSpec", mode: "specific", value_cents: BigDecimal(5_000)),
        edge(income_id: "A", account_id: "accLeft", mode: "leftover")
      ],
      obligations_by_account: { "accReq" => BigDecimal(12_000) },
      partners: [ P1 ],
      leftover_distribution: "income_ratio"
    ).plan
    assert_equal "-70.00", plan[:paychecks].first[:allocations].find { |x| x[:account_id] == "accLeft" }[:amount]
  end

  # 12. Two incomes into one bank: the band per income is its own edge
  # amount; the bank's allocations resolve off the combined inflow.
  test "two incomes into one bank share the combined inflow" do
    g = graph(
      month: Date.new(2026, 11, 1),
      incomes: [
        income(id: "A", owner_id: P1, amounts: [ 60_000 ]),
        income(id: "B", owner_id: P2, amounts: [ 40_000 ])
      ],
      allocations: [
        edge(income_id: "A", account_id: "C", mode: "leftover"),
        edge(income_id: "B", account_id: "C", mode: "leftover")
      ],
      plan_allocations: [
        alloc(id: "s1", account_id: "C", kind: "savings", mode: "specific", value_cents: BigDecimal(30_000))
      ]
    )

    c = g[:banks].find { |b| b[:id] == "C" }
    assert_equal "1000.00", c[:inflow_month]
    assert_equal "600.00", c[:inflow].find { |band| band[:income_id] == "A" }[:amount]
    assert_equal "400.00", c[:inflow].find { |band| band[:income_id] == "B" }[:amount]
    s1 = g[:allocations].find { |a| a[:id] == "s1" }
    assert_equal "300.00", s1[:got_month]
    assert_equal "700.00", c[:surplus_month]
    assert_equal [], g[:over_plans]
  end

  # 13. The suggested fix travels from the PR#1 computation into the graph
  # report (kept where it still applies, null otherwise).
  test "suggested fix is carried into the graph report" do
    g = graph(
      month: Date.new(2026, 11, 1),
      incomes: [
        income(id: "A", owner_id: P1, amounts: [ 100_000 ]),
        income(id: "B", owner_id: P2, amounts: [ 50_000 ])
      ],
      allocations: [
        edge(income_id: "A", account_id: "accPctA", mode: "percent", value_percent: BigDecimal(0.10)),
        edge(income_id: "A", account_id: "accLeftA", mode: "leftover"),
        edge(income_id: "B", account_id: "accPctB", mode: "percent", value_percent: BigDecimal(0.50)),
        edge(income_id: "B", account_id: "accLeftB", mode: "leftover")
      ],
      partners: [ P1, P2 ]
    )

    refute_nil g[:suggested_fix]
    assert_equal P1, g[:suggested_fix][:user_id]
    assert_equal "0.4250", g[:suggested_fix][:suggested_percent]
  end

  # Round 4 (ghost banks): a plan-ordered account with no flow must be a
  # bank in the graph — the Add Account modal sets plan_order only, and a
  # bank the diagram does not draw is a ghost: gone from the add-accounts
  # modal yet invisible (and unreachable) on the map.
  test "plan-ordered accounts with no flow are banks carrying their plan_order" do
    plan = graph(
      month: Date.new(2026, 11, 15),
      incomes: [ income(id: "A", owner_id: P1, amounts: [ 100_000 ]) ],
      plan_ordered: { "ghost-bank" => 1 }
    )

    bank = plan[:banks].find { |b| b[:id] == "ghost-bank" }
    assert bank, "the added-but-unlinked bank must appear in the graph banks"
    assert_equal "0.00", bank[:inflow_month]
    assert_equal "0.00", bank[:surplus_month]
    assert_equal 1, bank[:plan_order]
    assert bank[:inflow].empty?
  end

  # Round 11 issue 8 (fan-out, plan_graph only): (a) the parent's
  # per-paycheck reservation includes the child bases, (b) a child with no
  # own required edge draws its share of the parent's post-allocation pool
  # on the parent's funding dates.
  test "fan-out: parent reservation includes child bases and the child gets its pool share" do
    g = graph(
      month: Date.new(2026, 11, 1),
      incomes: [ income(id: "K", amounts: [ 90_000, 90_000 ]) ],
      allocations: [ edge(income_id: "K", account_id: "parent", mode: "required") ],
      plan_allocations: [
        alloc(id: "pb", account_id: "parent", name: "Bills", kind: "bill", mode: "required", value_cents: BigDecimal(40_000)),
        alloc(id: "cb", account_id: "child", name: "Bucket", kind: "savings", mode: "required", value_cents: BigDecimal(10_000))
      ],
      sub_account_links: { "child" => "parent" },
      auto_transfer_targets: { "parent" => [ "child" ] },
      account_names: { "parent" => "SoFi", "child" => "Bucket" }
    )

    # (a) Parent base = own 400 + child 100 = 500 over 2 funding paychecks.
    parent = g[:banks].find { |b| b[:id] == "parent" }
    assert_equal "500.00", parent[:inflow_month]
    assert_equal "250.00", parent[:inflow].first[:amount]

    # The parent's own bills pay first (200 of the 250 per paycheck).
    bills = g[:allocations].find { |a| a[:id] == "pb" }
    assert_equal "400.00", bills[:got_month]
    assert_equal "ok", bills[:status]

    # (b) The pool (50 per paycheck) splits by base share: the only child
    # gets 100% of it and its 100 monthly target is fully funded.
    bucket = g[:allocations].find { |a| a[:id] == "cb" }
    assert_equal "100.00", bucket[:wanted_month]
    assert_equal "100.00", bucket[:got_month]
    assert_equal "0.00", bucket[:shortfall_month]
    assert_equal "ok", bucket[:status]
    assert_equal "50.00", bucket[:per_paycheck].first[:wanted]
    assert_equal "50.00", bucket[:per_paycheck].first[:got]

    # Bank rows carry the sub-account link and the ordered targets.
    assert_equal false, parent[:sub_account]
    assert_nil parent[:parent_account_id]
    assert_equal [ "child" ], parent[:auto_transfer_target_ids]
    assert_equal "SoFi", parent[:name]
    child_row = g[:banks].find { |b| b[:id] == "child" }
    assert_equal true, child_row[:sub_account]
    assert_equal "parent", child_row[:parent_account_id]
    assert_equal "Bucket", child_row[:name]
  end

  # Round 11 issue 8 (fan-out): over-fan-out — the parent's own required
  # allocations resolve first, the buckets draw their base shares of what
  # is left, each short bucket reports its shortfall, and the over-plan
  # line names the income and the FIRST unsatisfied bucket (target order).
  test "fan-out over-plan: bills pay first, first unsatisfied bucket names the over-plan line" do
    g = graph(
      month: Date.new(2026, 11, 1),
      incomes: [ income(id: "K", amounts: [ 30_000, 30_000 ]) ],
      allocations: [ edge(income_id: "K", account_id: "parent", mode: "specific", value_cents: BigDecimal(30_000)) ],
      plan_allocations: [
        alloc(id: "pb", account_id: "parent", name: "Bills", kind: "bill", mode: "required", value_cents: BigDecimal(40_000)),
        alloc(id: "c1", account_id: "c1", name: "Bucket One", kind: "savings", mode: "required", value_cents: BigDecimal(30_000)),
        alloc(id: "c2", account_id: "c2", name: "Bucket Two", kind: "savings", mode: "required", value_cents: BigDecimal(30_000))
      ],
      sub_account_links: { "c1" => "parent", "c2" => "parent" },
      auto_transfer_targets: { "parent" => [ "c1", "c2" ] },
      account_names: { "parent" => "SoFi", "c1" => "Bucket One", "c2" => "Bucket Two" }
    )

    # The parent's own allocation is covered by the 300 inflow per paycheck.
    bills = g[:allocations].find { |a| a[:id] == "pb" }
    assert_equal "400.00", bills[:got_month]
    assert_equal "ok", bills[:status]

    # The pool is 100 per paycheck (300 - 200); each bucket's base share is
    # 50 of its 150 wanted, so both end 200 short monthly.
    c1 = g[:allocations].find { |a| a[:id] == "c1" }
    c2 = g[:allocations].find { |a| a[:id] == "c2" }
    assert_equal "300.00", c1[:wanted_month]
    assert_equal "100.00", c1[:got_month]
    assert_equal "200.00", c1[:shortfall_month]
    assert_equal "200.00", c2[:shortfall_month]

    # The parent's surplus line reflects the fan-out consumption: the 200
    # pool left of the bills all went to the buckets, nothing hidden.
    parent = g[:banks].find { |b| b[:id] == "parent" }
    assert_equal "0.00", parent[:surplus_month]

    flag = g[:over_plans].find { |f| f[:income_id] == "K" }
    assert flag, "the over-plan line must name the short income"
    assert_equal "bucket", flag[:target]
    assert_equal "c1", flag[:target_id] # first unsatisfied in target order
    assert_equal "200.00", flag[:shortfall_month]
  end

  # Round 11 issue 8 (fan-out, owner Q2): a child WITH its own required
  # edges resolves the own-edge pool independently; the fan-out pool adds
  # on top. The child's base is counted ONCE in the parent's reservation
  # (no double counting), and the fan-out transfer beyond the already-met
  # target accumulates in the child's bank surplus, not the allocation row.
  test "fan-out with own-edge child: pools resolve independently, demand counted once" do
    g = graph(
      month: Date.new(2026, 11, 1),
      incomes: [ income(id: "K", amounts: [ 50_000, 50_000 ]) ],
      allocations: [
        edge(income_id: "K", account_id: "parent", mode: "required"),
        edge(income_id: "K", account_id: "child", mode: "required")
      ],
      plan_allocations: [
        alloc(id: "pb", account_id: "parent", name: "Bills", kind: "bill", mode: "required", value_cents: BigDecimal(20_000)),
        alloc(id: "cb", account_id: "child", name: "Bucket", kind: "savings", mode: "required", value_cents: BigDecimal(10_000))
      ],
      sub_account_links: { "child" => "parent" },
      auto_transfer_targets: { "parent" => [ "child" ] }
    )

    # The child's own reservation: 100 base over 2 paychecks = 50 each.
    child = g[:banks].find { |b| b[:id] == "child" }
    assert_equal "100.00", child[:inflow_month]

    # The parent's reservation counts the child's base exactly once:
    # (200 + 100) / 2 = 150 per paycheck, not (200 + 100 + 100) / 2.
    parent = g[:banks].find { |b| b[:id] == "parent" }
    assert_equal "300.00", parent[:inflow_month]

    # The allocation's wanted stays its own proration (no double-counted
    # wanted) and it is fully funded from the own-edge pool.
    bucket = g[:allocations].find { |a| a[:id] == "cb" }
    assert_equal "100.00", bucket[:wanted_month]
    assert_equal "100.00", bucket[:got_month]
    assert_equal "0.00", bucket[:shortfall_month]
    assert_equal "ok", bucket[:status]

    # The fan-out transfer (the 50-per-paycheck pool) tops up nothing —
    # the target is met — so it accumulates in the child's bank surplus.
    assert_equal "100.00", child[:surplus_month]
    assert_equal "0.00", parent[:surplus_month]
    assert_empty g[:over_plans]
  end

  # Round 11 issue 8 (fan-out, draft parity): the fan-out inputs are
  # SAVED state, not draftable — a wholesale draft edge swap must leave
  # the sub-account/fan-out inputs intact and resolve against the drafted
  # inflow.
  test "fan-out inputs survive the draft merge (parity unchanged)" do
    base = {
      month: Date.new(2026, 11, 1),
      incomes: [ income(id: "K", amounts: [ 90_000, 90_000 ]) ],
      plan_allocations: [
        alloc(id: "pb", account_id: "parent", name: "Bills", kind: "bill", mode: "required", value_cents: BigDecimal(40_000)),
        alloc(id: "cb", account_id: "child", name: "Bucket", kind: "savings", mode: "required", value_cents: BigDecimal(10_000))
      ],
      sub_account_links: { "child" => "parent" },
      auto_transfer_targets: { "parent" => [ "child" ] }
    }

    plain = graph(
      allocations: [ edge(income_id: "K", account_id: "parent", mode: "required") ],
      **base
    )
    drafted = graph(
      allocations: [ edge(income_id: "K", account_id: "parent", mode: "required") ],
      draft: { allocations: [ edge(income_id: "K", account_id: "parent", mode: "percent", value_percent: 0.5) ] },
      **base
    )

    # The saved fan-out inputs are untouched by the wholesale edge swap.
    parent = drafted[:banks].find { |b| b[:id] == "parent" }
    assert_equal [ "child" ], parent[:auto_transfer_target_ids]
    assert_equal true, drafted[:banks].find { |b| b[:id] == "child" }[:sub_account]

    # The drafted inflow (450 per paycheck) funds the bills (200) and the
    # pool (250); the bucket takes its 50 wanted and the excess 200
    # accumulates in the child's bank surplus.
    assert_equal "450.00", parent[:inflow].first[:amount]
    bucket = drafted[:allocations].find { |a| a[:id] == "cb" }
    assert_equal "100.00", bucket[:got_month]
    assert_equal "ok", bucket[:status]
    assert_equal "400.00", drafted[:banks].find { |b| b[:id] == "child" }[:surplus_month]
    assert_equal "0.00", parent[:surplus_month]
  end

  # Round 16 (owner note 4): the plaintext last-4 rides on every bank row,
  # nil when the account has no mask — never a fabricated digit.
  test "bank rows carry the last-4 map value, nil when the bank has no mask" do
    g = graph(
      month: Date.new(2026, 11, 1),
      incomes: [ income(id: "A", amounts: [ 100_000 ]) ],
      allocations: [
        edge(income_id: "A", account_id: "chk", mode: "leftover"),
        edge(income_id: "A", account_id: "sav", mode: "leftover")
      ],
      account_names: { "chk" => "SoFi Savings", "sav" => "Navy Savings" },
      account_last4s: { "chk" => "8979" }
    )

    chk = g[:banks].find { |b| b[:id] == "chk" }
    sav = g[:banks].find { |b| b[:id] == "sav" }
    assert_equal "8979", chk[:last4]
    assert_nil sav[:last4]
  end

  # Round 16 (owner note 3b): the logo slug resolution order — explicit
  # per-account override wins when usable; otherwise the first (longest-first)
  # keyword hit on the account name; otherwise nil. Only slugs from the
  # vendored set are ever emitted.
  test "bank rows carry the logo slug in resolution order (explicit, keyword, nil)" do
    g = graph(
      month: Date.new(2026, 11, 1),
      incomes: [ income(id: "A", amounts: [ 100_000 ]) ],
      allocations: [
        edge(income_id: "A", account_id: "sofi", mode: "leftover"),
        edge(income_id: "A", account_id: "navy", mode: "leftover"),
        edge(income_id: "A", account_id: "other", mode: "leftover"),
        edge(income_id: "A", account_id: "stale", mode: "leftover")
      ],
      account_names: {
        "sofi" => "SoFi Savings",
        "navy" => "NAVY Vari Bills",
        "other" => "Some Unknown Bank",
        "stale" => "Stale Override"
      },
      # "sofi" has an explicit slug; "stale" has an explicit slug that is NOT
      # in the vendored set (must fall through to the keyword match, miss, nil).
      account_bank_logos: { "sofi" => "sofi", "stale" => "not-vendored" },
      bank_logo_keywords: [ [ "navyfederal", "navy-federal" ], [ "navy", "navy-federal" ], [ "sofi", "sofi" ] ],
      bank_logos: { "sofi" => "SoFi", "navy-federal" => "Navy Federal Credit Union" }
    )

    assert_equal "sofi", g[:banks].find { |b| b[:id] == "sofi" }[:logo]
    # "NAVY Vari Bills" normalizes to "navyvaribills" -> keyword "navy" hit.
    assert_equal "navy-federal", g[:banks].find { |b| b[:id] == "navy" }[:logo]
    assert_nil g[:banks].find { |b| b[:id] == "other" }[:logo]
    # Explicit slug missing from the vendored set is ignored, no keyword hit.
    assert_nil g[:banks].find { |b| b[:id] == "stale" }[:logo]
    # The usable logo set rides at the payload root, sorted by label.
    assert_equal [ { slug: "navy-federal", label: "Navy Federal Credit Union" },
                   { slug: "sofi", label: "SoFi" } ],
                 g[:available_bank_logos]
  end

  # Round 16 (owner note 3b): longest keyword wins when several match.
  test "longest keyword wins when several match the account name" do
    g = graph(
      month: Date.new(2026, 11, 1),
      incomes: [ income(id: "A", amounts: [ 100_000 ]) ],
      allocations: [ edge(income_id: "A", account_id: "navyfed", mode: "leftover") ],
      account_names: { "navyfed" => "Navy Federal Savings" },
      # Both keywords hit the normalized name; the LONGER one must win.
      # (If "navy" were tried first it would resolve to "ally" instead.)
      bank_logo_keywords: [ [ "navy", "ally" ], [ "navyfederal", "navy-federal" ] ],
      bank_logos: { "ally" => "Ally Financial", "navy-federal" => "Navy Federal Credit Union" }
    )

    assert_equal "navy-federal", g[:banks].find { |b| b[:id] == "navyfed" }[:logo]
  end

  # Round 16 (owner note 2): the allocation rows carry the Sure category's
  # name + color so the diagram band matches the category; nil / nil when the
  # allocation has no category (never a fabricated color).
  test "allocation rows carry the category name and color, nil when unset" do
    g = graph(
      month: Date.new(2026, 11, 1),
      incomes: [ income(id: "A", amounts: [ 100_000 ]) ],
      allocations: [ edge(income_id: "A", account_id: "chk", mode: "leftover") ],
      account_names: { "chk" => "SoFi Savings" },
      plan_allocations: [
        alloc(id: "b1", account_id: "chk", name: "Bills", kind: "bill",
              mode: "required", value_cents: BigDecimal(50_000), category_id: "cat-1"),
        alloc(id: "b2", account_id: "chk", name: "No Cat", kind: "bill",
              mode: "required", value_cents: BigDecimal(20_000), category_id: nil)
      ],
      categories: { "cat-1" => { name: "Groceries", color: "#6172F3" } }
    )

    b1 = g[:allocations].find { |a| a[:id] == "b1" }
    b2 = g[:allocations].find { |a| a[:id] == "b2" }
    assert_equal "Groceries", b1[:category_name]
    assert_equal "#6172F3", b1[:category_color]
    assert_nil b2[:category_name]
    assert_nil b2[:category_color]
  end

  # Round 16 (owner note 2): a category id that is NOT in the categories map
  # (deleted / foreign) still reads nil — no fabricated color.
  test "allocation rows read nil when the category id is absent from the map" do
    g = graph(
      month: Date.new(2026, 11, 1),
      incomes: [ income(id: "A", amounts: [ 100_000 ]) ],
      allocations: [ edge(income_id: "A", account_id: "chk", mode: "leftover") ],
      account_names: { "chk" => "SoFi Savings" },
      plan_allocations: [
        alloc(id: "b1", account_id: "chk", name: "Bills", kind: "bill",
              mode: "required", value_cents: BigDecimal(50_000), category_id: "missing")
      ],
      categories: {}
    )

    b1 = g[:allocations].find { |a| a[:id] == "b1" }
    assert_nil b1[:category_name]
    assert_nil b1[:category_color]
  end
end
