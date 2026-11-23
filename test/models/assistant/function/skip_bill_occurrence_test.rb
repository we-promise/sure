require "test_helper"

class Assistant::Function::SkipBillOccurrenceTest < ActiveSupport::TestCase
  setup do
    @user = users(:family_admin)
    @family = @user.family
    @family.recurring_transactions.destroy_all
  end

  test "skips the open occurrence on that date, as Skip on the Bills page does" do
    series = create_series(name: "Gym", amount: 40)
    occurrence = series.recurring_occurrences.open_status.order(:due_on).first

    result = call_tool(series.id, "occurrence_due_on" => occurrence.due_on.iso8601)

    assert result[:skipped], result[:error]
    assert_equal "skipped", result[:occurrence][:status]
    assert occurrence.reload.skipped?
    assert_equal "user", occurrence.closed_source
    assert_not_equal occurrence.due_on, series.reload.next_due_date, "a skipped date is no longer what the bill waits on"
  end

  test "payments already recorded on the occurrence are kept" do
    series = create_series(name: "Gym", amount: 40)
    occurrence = series.recurring_occurrences.open_status.order(:due_on).first
    occurrence.allocations.create!(allocated_amount: 10, currency: "USD", source: "user_created")

    assert call_tool(series.id, "occurrence_due_on" => occurrence.due_on.iso8601)[:skipped]
    assert_equal 1, occurrence.allocations.confirmed.count
  end

  test "an occurrence already closed is reported, not skipped again" do
    series = create_series(name: "Gym", amount: 40)
    occurrence = series.recurring_occurrences.open_status.order(:due_on).first
    occurrence.skip!

    result = call_tool(series.id, "occurrence_due_on" => occurrence.due_on.iso8601)

    assert_match(/already skipped/, result[:error])
    assert_match(/Do not retry/, result[:hint])
  end

  test "an unknown date lists the open due dates to pick from" do
    series = create_series(name: "Gym", amount: 40)
    open = series.recurring_occurrences.open_status.order(:due_on).first

    result = call_tool(series.id, "occurrence_due_on" => (open.due_on + 1).iso8601)

    assert_match(/No occurrence/, result[:error])
    assert_includes result[:hint], open.due_on.iso8601
  end

  test "an unparseable date is refused" do
    series = create_series(name: "Gym", amount: 40)

    assert_equal "occurrence_due_on is not a valid date", call_tool(series.id, "occurrence_due_on" => "soon")[:error]
  end

  test "a read-only account share cannot skip an occurrence" do
    series = create_series(name: "Shared Sub", amount: 12, account: accounts(:credit_card))
    occurrence = series.recurring_occurrences.open_status.order(:due_on).first

    result = Assistant::Function::SkipBillOccurrence.new(users(:family_member)).call(
      "bill_id" => series.id.to_s, "occurrence_due_on" => occurrence.due_on.iso8601
    )

    assert_match(/read-only/, result[:error])
    assert occurrence.reload.scheduled?
  end

  private

    def call_tool(bill_id, params)
      Assistant::Function::SkipBillOccurrence.new(@user).call({ "bill_id" => bill_id.to_s }.merge(params))
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
        bill_type: "bill"
      }.merge(overrides))
    end
end
