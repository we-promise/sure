require "test_helper"

class Assistant::Function::GetBillDetailsTest < ActiveSupport::TestCase
  setup do
    @user = users(:family_admin)
    @family = @user.family
    @family.recurring_transactions.destroy_all
  end

  test "analytics come from confirmed payments on settled occurrences, never estimates" do
    series = create_series(name: "CITY WATER", amount: 200)
    paid = series.recurring_occurrences.order(:due_on).first
    paid.allocations.create!(allocated_amount: 100, currency: "USD", source: "user_created")
    paid.close!("paid", source: "user")
    # An open occurrence still expecting the estimated 200 must not move the average.

    result = call_tool(series.id)

    assert_equal "$100.00", result[:analytics][:average_paid],
      "the open occurrence's 200 estimate must not be averaged in"
    assert_equal "$100.00", result[:analytics][:paid_this_year]
  end

  test "analytics are null before anything was paid" do
    series = create_series(name: "Fresh bill", amount: 50)

    result = call_tool(series.id)

    assert_nil result[:analytics]
  end

  test "history rows carry their payments with the transaction name" do
    series = create_series(name: "CITY WATER", amount: 80)
    entry = accounts(:depository).entries.create!(
      date: Date.current, amount: 80, currency: "USD", name: "CITY WATER PMT",
      entryable: Transaction.new
    )
    occurrence = series.recurring_occurrences.order(:due_on).first
    occurrence.allocations.create!(entry: entry, allocated_amount: 80, currency: "USD", source: "user_confirmed")
    occurrence.close!("paid", source: "user")

    result = call_tool(series.id)

    payment = result[:history].sole[:payments].sole
    assert_equal "CITY WATER PMT", payment[:transaction_name]
    assert_equal "user_confirmed", payment[:source]
  end

  test "price changes serialize with the percent" do
    series = create_series(name: "Stream Co", amount: 12)
    series.recurring_price_changes.create!(
      effective_on: Date.current - 10, previous_amount: 10, new_amount: 12,
      currency: "USD", source: "detected"
    )

    result = call_tool(series.id)

    change = result[:price_changes].sole
    assert_equal "$10.00", change[:previous_amount]
    assert_equal "$12.00", change[:new_amount]
    assert_in_delta 20.0, change[:percent_change]
  end

  test "an invalid uuid returns an error with a hint" do
    result = call_tool("not-a-uuid")

    assert result[:error].present?
    assert_includes result[:hint], "get_bills"
  end

  test "another family's bill raises RecordNotFound for the caller to convert" do
    other = families(:empty).recurring_transactions.create!(
      name: "Foreign bill", amount: 10, currency: "USD",
      expected_day_of_month: 1, last_occurrence_date: Date.current,
      next_expected_date: 1.month.from_now.to_date, status: "active"
    )

    assert_raises(ActiveRecord::RecordNotFound) { call_tool(other.id) }
  end

  private

    def call_tool(bill_id)
      Assistant::Function::GetBillDetails.new(@user).call({ "bill_id" => bill_id.to_s })
    end

    def create_series(name:, amount:, **overrides)
      @family.recurring_transactions.create!({
        name: name,
        account: accounts(:depository),
        amount: amount,
        dedup_scope: "#{name}-#{amount}",
        currency: "USD",
        expected_day_of_month: Date.current.day,
        last_occurrence_date: 1.month.ago.to_date,
        next_expected_date: Date.current,
        status: "active"
      }.merge(overrides))
    end
end
