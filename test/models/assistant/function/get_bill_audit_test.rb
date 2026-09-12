require "test_helper"

class Assistant::Function::GetBillAuditTest < ActiveSupport::TestCase
  setup do
    @user = users(:family_admin)
    @family = @user.family
    @family.recurring_transactions.destroy_all
  end

  test "flags exact duplicates but never subscription tiers" do
    create_series(name: "Streaming Co", amount: 15.99, dedup_scope: "a")
    create_series(name: "Streaming Co", amount: 15.99, dedup_scope: "b")
    # A different tier to the same merchant: same name, different amount.
    create_series(name: "Streaming Co", amount: 24.99, dedup_scope: "c")

    result = call_tool

    duplicates = result[:possible_duplicates][:items]
    assert_equal 1, duplicates.size
    assert_equal 2, duplicates.sole[:bills].size,
      "the 24.99 tier must not be flagged as a duplicate of the 15.99 pair"
  end

  test "reports price changes inside the lookback and trials about to convert" do
    series = create_series(name: "Stream Co", amount: 12)
    series.recurring_price_changes.create!(
      effective_on: Date.current - 20, previous_amount: 10, new_amount: 12,
      currency: "USD", source: "detected"
    )
    create_series(name: "Trial service", amount: 9, trial_ends_on: Date.current + 5)

    result = call_tool

    assert_equal 1, result[:price_changes][:count]
    assert_in_delta 20.0, result[:price_changes][:items].sole[:percent_change]
    assert_equal "Trial service", result[:upcoming_trials][:items].sole[:name]
  end

  test "suggested detections wait in awaiting_confirmation" do
    create_series(name: "Detected sub", amount: 8, status: "suggested", manual: false)

    result = call_tool

    assert_equal 1, result[:awaiting_confirmation][:count]
    assert_equal "Detected sub", result[:awaiting_confirmation][:items].sole[:name]
  end

  test "surfaces recurring charge patterns no series covers" do
    3.times do |i|
      accounts(:depository).entries.create!(
        date: Date.current - i.months, amount: 40, currency: "USD",
        name: "GYM MEMBERSHIP", entryable: Transaction.new
      )
    end

    result = call_tool

    candidate = result[:undeclared_candidates][:items].find { |item| item[:name] == "GYM MEMBERSHIP" }
    assert candidate.present?, "the undeclared gym pattern must surface"
    assert_operator candidate[:occurrence_count], :>=, 2
  end

  test "undeclared candidates never include accounts the user cannot reach" do
    3.times do |i|
      accounts(:investment).entries.create!(
        date: Date.current - i.months, amount: 25, currency: "USD",
        name: "BROKERAGE FEE", entryable: Transaction.new
      )
    end

    admin_names = call_tool[:undeclared_candidates][:items].map { |item| item[:name] }
    assert_includes admin_names, "BROKERAGE FEE",
      "positive control: the admin can see the investment-account pattern"

    member_result = Assistant::Function::GetBillAudit.new(users(:family_member)).call
    member_names = member_result[:undeclared_candidates][:items].map { |item| item[:name] }
    assert_not_includes member_names, "BROKERAGE FEE",
      "a pattern on an account the member was never given must not leak"
  end

  test "long_overdue measures in the bill's own cycles" do
    overdue_day = 45.days.ago.to_date
    series = create_series(name: "Forgotten bill", amount: 60,
                           expected_day_of_month: overdue_day.day,
                           last_occurrence_date: overdue_day << 1,
                           next_expected_date: overdue_day)

    # The cycle actually left unpaid is what makes a bill overdue. Declared
    # series do not fabricate past occurrences, so the one that was forgotten
    # has to exist for there to be anything to forget.
    series.recurring_occurrences.destroy_all
    series.recurring_occurrences.create!(
      family: @family, original_due_on: overdue_day, due_on: overdue_day,
      currency: "USD", expected_amount: 60, status: "scheduled"
    )

    result = call_tool

    row = result[:long_overdue][:items].find { |item| item[:name] == "Forgotten bill" }
    assert row.present?
    assert_operator row[:cycles_overdue], :>=, 1
  end

  # Same contract as get_bills' due_within_days: out-of-range values are
  # rejected, not silently clamped onto a different question.
  test "an out-of-range lookback_months is rejected, not silently adjusted" do
    assert_match(/between 1 and 24/, call_tool("lookback_months" => 0)[:error])
    assert_match(/between 1 and 24/, call_tool("lookback_months" => "forever")[:error])
    assert_match(/between 1 and 24/, call_tool("lookback_months" => 36)[:error])
    assert_nil call_tool("lookback_months" => 6)[:error]
    assert_nil call_tool({})[:error]
  end

  private

    def call_tool(params = {})
      Assistant::Function::GetBillAudit.new(@user).call(params)
    end

    def create_series(name:, amount:, dedup_scope: nil, **overrides)
      @family.recurring_transactions.create!({
        name: name,
        account: accounts(:depository),
        amount: amount,
        dedup_scope: dedup_scope || "#{name}-#{amount}",
        currency: "USD",
        expected_day_of_month: Date.current.day,
        last_occurrence_date: 1.month.ago.to_date,
        next_expected_date: Date.current,
        status: "active"
      }.merge(overrides))
    end
end
