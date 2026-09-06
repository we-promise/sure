require "test_helper"

class Assistant::Function::GetUncategorizedTransactionsTest < ActiveSupport::TestCase
  setup do
    @user = users(:family_admin)
    @family = @user.family
    @account = accounts(:depository)
    @fn = Assistant::Function::GetUncategorizedTransactions.new(@user)
  end

  def create_uncategorized(name:, amount:, date: Date.current, account: @account)
    Entry.create!(
      account: account,
      name: name,
      date: date,
      amount: amount,
      currency: account.currency,
      entryable: Transaction.new
    )
  end

  test "has correct name and is not strict" do
    assert_equal "get_uncategorized_transactions", @fn.name
    refute @fn.to_definition[:strict]
  end

  test "groups the same payee across differently dated bank labels" do
    create_uncategorized(name: "CB 02/09 CARREFOUR MARKET", amount: 86.42, date: Date.current - 40)
    create_uncategorized(name: "CB 04/10 CARREFOUR MARKET", amount: 51.10, date: Date.current - 10)

    result = @fn.call

    carrefour = result[:payees].find { |p| p[:payee] == "CARREFOUR MARKET" }

    assert_not_nil carrefour, "the two labels must collapse into one payee"
    assert_equal 2, carrefour[:transaction_count]
    assert_equal 137.52, carrefour[:total_amount].to_f
    assert_equal "card", carrefour[:rail]
    assert_equal [ @account.name ], carrefour[:accounts]
    assert_equal 2, carrefour[:transaction_ids].size
  end

  test "orders payees by absolute total and reports a summary" do
    create_uncategorized(name: "PRLV SEPA SMALL", amount: 5)
    create_uncategorized(name: "PRLV SEPA BIG", amount: 900)

    result = @fn.call

    assert_equal "BIG", result[:payees].first[:payee]
    assert result[:summary][:transaction_count] >= 2
    assert result[:summary][:totals_by_currency][@account.currency][:expense][:formatted].present?
  end

  test "keeps totals separate per currency instead of blending them" do
    foreign = @family.accounts.create!(
      name: "Compte GBP",
      balance: 0,
      currency: "GBP",
      accountable: Depository.new
    )
    create_uncategorized(name: "PRLV SEPA BLENDED", amount: 100)
    create_uncategorized(name: "PRLV SEPA BLENDED", amount: 100, account: foreign)

    result = @fn.call

    totals = result[:summary][:totals_by_currency]

    assert_equal 2, totals.keys.size
    assert_includes totals.keys, "GBP"

    blended = result[:payees].select { |p| p[:payee] == "BLENDED" }

    assert_equal 2, blended.size, "one payee billed in two currencies is two rows, not one blended total"
    assert_equal [ "GBP", @account.currency ].sort, blended.map { |p| p[:currency] }.sort
  end

  # Entry.uncategorized_transactions drops every Transaction::TRANSFER_KINDS
  # member, but the budget model only excludes BUDGET_EXCLUDED_KINDS. A loan
  # payment IS spending here, so an uncategorized one is part of the gap this
  # tool reports, and hiding it understates that gap silently.
  test "lists the transfer kinds the budget counts as spending" do
    loan = create_uncategorized(name: "PRLV SEPA CREDIT AUTO", amount: 250)
    loan.entryable.update!(kind: "loan_payment")

    contribution = create_uncategorized(name: "VIR SEPA PEA", amount: 400)
    contribution.entryable.update!(kind: "investment_contribution")

    payees = @fn.call[:payees].map { |p| p[:payee] }

    assert_includes payees, "CREDIT AUTO"
    assert_includes payees, "PEA"
  end

  # A signed sum let one uncategorized salary cancel the purchases it was meant
  # to be measured against, so the summary could understate the backlog or
  # report it with the wrong sign entirely.
  test "reports income and expense separately instead of netting them" do
    create_uncategorized(name: "PRLV SEPA COURSES", amount: 200)
    before = @fn.call[:summary][:totals_by_currency][@account.currency]

    create_uncategorized(name: "VIR SEPA SALAIRE", amount: -3000)
    totals = @fn.call[:summary][:totals_by_currency][@account.currency]

    assert_equal before[:expense][:amount].to_f, totals[:expense][:amount].to_f,
                 "an uncategorized inflow must not cancel uncategorized spending"
    assert_equal before[:expense][:transaction_count], totals[:expense][:transaction_count]
    assert_equal 3000, totals[:income][:amount].to_f - before[:income][:amount].to_f
    assert_equal 1, totals[:income][:transaction_count] - before[:income][:transaction_count]
  end

  # The whole window is materialized to normalize and group labels, so an
  # unbounded start_date would load a family's entire history to return at most
  # MAX_PAYEES rows.
  test "clamps a start_date beyond the maximum lookback" do
    max_days = Assistant::Function::GetUncategorizedTransactions::MAX_LOOKBACK_DAYS
    create_uncategorized(name: "PRLV SEPA ANCIEN", amount: 42, date: Date.current - max_days - 60)

    result = @fn.call("start_date" => (Date.current - 3000).to_s)

    assert_equal Date.current - max_days, result[:period][:start_date]
    assert_not_includes result[:payees].map { |p| p[:payee] }, "ANCIEN"
  end

  test "never lists transfers or excluded rows" do
    transfer_entry = create_uncategorized(name: "PRLV SEPA INTERNAL MOVE", amount: 300)
    transfer_entry.entryable.update!(kind: "funds_movement")

    excluded_entry = create_uncategorized(name: "PRLV SEPA IGNORED ROW", amount: 400)
    excluded_entry.update!(excluded: true)

    payees = @fn.call[:payees].map { |p| p[:payee] }

    assert_not_includes payees, "INTERNAL MOVE"
    assert_not_includes payees, "IGNORED ROW"
  end

  test "honors the date window" do
    create_uncategorized(name: "PRLV SEPA OLD ONE", amount: 42, date: Date.current - 400)

    in_window = @fn.call("start_date" => (Date.current - 30).to_s)
    wide = @fn.call("start_date" => (Date.current - 500).to_s)

    assert_not_includes in_window[:payees].map { |p| p[:payee] }, "OLD ONE"
    assert_includes wide[:payees].map { |p| p[:payee] }, "OLD ONE"
  end

  test "restricts to accessible accounts and ignores foreign ids" do
    other_family_account = accounts(:investment)

    result = @fn.call("account_ids" => [ other_family_account.id ])

    member = Assistant::Function::GetUncategorizedTransactions.new(users(:family_member))
    member_result = member.call("account_ids" => [ other_family_account.id ])

    assert result.key?(:payees)
    assert_empty member_result[:payees]
  end

  test "prefers a real merchant name over the cleaned label" do
    entry = create_uncategorized(name: "CB 02/09 SOMETHING RAW", amount: 20)
    entry.entryable.update!(merchant: merchants(:netflix))

    payees = @fn.call[:payees]
    matched = payees.find { |p| p[:payee] == merchants(:netflix).name }

    assert_not_nil matched
    assert_nil matched[:rail], "a known merchant needs no rail guess"
  end

  test "reports that nothing enriches automatically when no rule exists" do
    @family.rules.destroy_all

    enrichment = @fn.call[:enrichment]

    assert_equal "absent", enrichment[:auto_categorize_rule]
    assert_equal "absent", enrichment[:auto_detect_merchants_rule]
    assert_match(/No active rule runs auto-categorization/, enrichment[:note])
  end

  test "distinguishes an inactive rule from a missing one" do
    @family.rules.destroy_all
    @family.rules.create!(
      resource_type: "transaction",
      active: false,
      actions_attributes: [ { action_type: "auto_categorize" } ]
    )

    enrichment = @fn.call[:enrichment]

    assert_equal "inactive", enrichment[:auto_categorize_rule]
    assert_equal "absent", enrichment[:auto_detect_merchants_rule]
  end

  test "reports an active rule as active" do
    @family.rules.destroy_all
    @family.rules.create!(
      resource_type: "transaction",
      active: true,
      actions_attributes: [
        { action_type: "auto_categorize" },
        { action_type: "auto_detect_merchants" }
      ]
    )

    enrichment = @fn.call[:enrichment]

    assert_equal "active", enrichment[:auto_categorize_rule]
    assert_equal "active", enrichment[:auto_detect_merchants_rule]
  end

  test "flags truncation instead of silently dropping payees" do
    3.times { |i| create_uncategorized(name: "PRLV SEPA PAYEE#{i}", amount: 10 + i) }

    result = @fn.call("limit" => 1)

    assert_equal 1, result[:payees].size
    assert result[:truncated]
  end
end
