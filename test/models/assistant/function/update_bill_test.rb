require "test_helper"

class Assistant::Function::UpdateBillTest < ActiveSupport::TestCase
  setup do
    @user = users(:family_admin)
    @family = @user.family
    @family.recurring_transactions.destroy_all
  end

  test "amount arrives as magnitude and income keeps its sign" do
    income = create_series(name: "Paycheck", amount: -1200, bill_type: "income")

    result = call_tool(income.id, "amount" => 1300)

    assert result[:updated]
    assert_equal(-1300, income.reload.amount.to_f,
      "a raw assignment would have flipped the paycheck into a bill")
  end

  test "a non-numeric amount is refused with a hint, not raised" do
    series = create_series(name: "Gym", amount: 40)

    result = call_tool(series.id, "amount" => "twenty")

    assert result[:error].present?
    assert result[:hint].present?
    assert_equal 40, series.reload.amount.to_f
  end

  test "a schedule change applies the preset and pins it against detection" do
    series = create_series(name: "Gym", amount: 40)
    refute series.schedule_pinned?

    result = call_tool(series.id, "frequency" => "weekly", "weekday" => 5)

    assert result[:updated]
    assert_includes result[:changed_fields], "schedule"
    assert series.reload.schedule_pinned?,
      "an AI-applied cadence is user intent by proxy; detection must not move it back"
  end

  test "paused maps to the stored value the UI's own Pause writes" do
    series = create_series(name: "Gym", amount: 40)

    result = call_tool(series.id, "status" => "paused")

    assert result[:updated]
    assert_equal "inactive", series.reload.status
    assert_equal "paused", result[:bill][:status], "but the tool answers in the UI vocabulary"
  end

  test "an amount change pins occurrences already due instead of restating them" do
    overdue_day = 10.days.ago.to_date
    series = create_series(name: "Rent", amount: 2000,
                           expected_day_of_month: overdue_day.day,
                           anchor_date: overdue_day,
                           last_occurrence_date: overdue_day << 1,
                           next_expected_date: overdue_day)
    past_due = series.recurring_occurrences.open_status.find_by!(due_on: overdue_day)

    call_tool(series.id, "amount" => 2500)

    assert_equal 2000, past_due.reload.resolved_expected_amount.to_f,
      "raising the rent must not restate what last month's unpaid rent claims"
  end

  test "an invalid renews_on is rejected instead of silently clearing" do
    series = create_series(name: "Gym", amount: 40)

    result = call_tool(series.id, "renews_on" => "not-a-date")

    assert_equal "renews_on is not a valid date", result[:error]
    assert_equal "Use YYYY-MM-DD.", result[:hint]
    assert_nil series.reload.renews_on

    result = call_tool(series.id, "renews_on" => "2027-03-01")

    assert result[:updated]
    assert_equal Date.new(2027, 3, 1), series.reload.renews_on
  end

  test "kind cannot leave the editable set" do
    income = create_series(name: "Paycheck", amount: -1200, bill_type: "income")

    result = call_tool(income.id, "bill_type" => "bill")

    assert result[:error].present?
    assert_equal "income", income.reload.bill_type
  end

  test "an inaccessible account name returns a hint" do
    series = create_series(name: "Gym", amount: 40)

    result = call_tool(series.id, "account_name" => "No Such Account")

    assert_match(/No account named/, result[:error])
    assert_includes result[:hint], "get_accounts"
  end

  test "no recognized fields is an error, not a silent no-op" do
    series = create_series(name: "Gym", amount: 40)

    result = call_tool(series.id, "unknown_field" => "x")

    assert_match(/No recognized fields/, result[:error])
  end

  private

    def call_tool(bill_id, params)
      Assistant::Function::UpdateBill.new(@user).call({ "bill_id" => bill_id.to_s }.merge(params))
    end

    def create_series(name:, amount:, **overrides)
      @family.recurring_transactions.create!({
        name: name,
        account: accounts(:depository),
        amount: amount,
        dedup_scope: "#{name}-#{amount}",
        currency: "USD",
        expected_day_of_month: Date.current.day,
        anchor_date: Date.current,
        last_occurrence_date: 1.month.ago.to_date,
        next_expected_date: Date.current,
        status: "active",
        manual: true,
        bill_type: amount.to_d.negative? ? "income" : "bill"
      }.merge(overrides))
    end
end
