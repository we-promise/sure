require "test_helper"

class Assistant::Function::RecordBillPaymentTest < ActiveSupport::TestCase
  setup do
    @user = users(:family_admin)
    @family = @user.family
    @family.recurring_transactions.destroy_all
    @series = @family.recurring_transactions.create!(
      name: "Rent", account: accounts(:depository), amount: 2000, currency: "USD",
      expected_day_of_month: Date.current.day, anchor_date: Date.current,
      last_occurrence_date: 1.month.ago.to_date, next_expected_date: Date.current,
      status: "active", manual: true
    )
    @occurrence = @series.recurring_occurrences.open_status.order(:due_on).first
  end

  test "omitting amount settles the occurrence in full" do
    result = call_tool({})

    assert result[:recorded]
    assert_equal "paid", result[:occurrence][:status]
    assert @occurrence.reload.paid?
    assert_equal 2000, @occurrence.allocations.sum(:allocated_amount)
  end

  test "a backdated full settlement carries its payment date into the allocation" do
    paid_on = Date.current - 6

    result = call_tool("paid_on" => paid_on.iso8601)

    assert result[:recorded]
    assert_equal paid_on, @occurrence.reload.allocations.sole.paid_on,
      "the settlement must record the stated payment date, not today"
  end

  test "a partial payment leaves the occurrence open and partially paid" do
    result = call_tool("amount" => 500)

    assert result[:recorded]
    occurrence = @occurrence.reload
    assert occurrence.scheduled?, "500 against 2000 is not rent"
    assert occurrence.partially_paid?
    assert_equal "$1,500.00", result[:occurrence][:remaining]
  end

  test "an invalid payment amount is refused with a hint, not raised" do
    result = call_tool("amount" => 0)

    assert result[:error].present?
    assert_includes result[:hint], "get_bill_details"
    assert_equal 0, @occurrence.reload.allocations.count
  end

  test "after settling, the next open occurrence becomes the payable one" do
    call_tool({})

    result = call_tool("amount" => 100)

    assert result[:recorded], "the series' next open occurrence takes the payment"
    next_open = @series.recurring_occurrences.open_status.order(:due_on).first
    assert next_open.partially_paid?
  end

  test "a closed or unknown due date lists the open ones" do
    result = call_tool("occurrence_due_on" => (Date.current - 3).iso8601)

    assert_match(/No open occurrence/, result[:error])
    assert_includes result[:hint], @occurrence.due_on.iso8601
  end

  test "payments go through the Allocator write path" do
    result = call_tool("amount" => 500, "paid_on" => (Date.current - 1).iso8601)

    assert result[:recorded]
    allocation = @occurrence.allocations.sole
    assert_equal "user_created", allocation.source
    assert_equal Date.current - 1, allocation.paid_on
  end

  private

    def call_tool(params)
      Assistant::Function::RecordBillPayment.new(@user).call({ "bill_id" => @series.id.to_s }.merge(params))
    end
end
