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


  # An LLM retries on timeout. Every payment recorded through this tool was
  # capped by nothing, because the allocator only guarded payments attached to
  # a bank entry. Two identical calls settled a $2,000 bill at $3,000.
  test "a repeated partial payment cannot overfill the cycle" do
    series = declare_capped_bill(amount: 2000)
    args = { "bill_id" => series.id, "amount" => 1500 }

    first = Assistant::Function::RecordBillPayment.new(@user).call(args)
    second = Assistant::Function::RecordBillPayment.new(@user).call(args)

    assert first[:recorded]
    assert second[:error].present?, "the retry must be refused, not absorbed"
    assert_match(/more than the/, second[:error])

    occurrence = series.recurring_occurrences.order(:due_on).first
    assert_equal 1500, occurrence.allocations.confirmed.sum(:allocated_amount)
  end

  test "an amount larger than the cycle owes is refused" do
    series = declare_capped_bill(amount: 2000)

    result = Assistant::Function::RecordBillPayment.new(@user).call("bill_id" => series.id, "amount" => 999_999)

    assert result[:error].present?
    assert_equal 0, series.recurring_occurrences.order(:due_on).first.allocations.count
  end

  # After a cycle settles, the next one becomes current. A retried settle used
  # to fall through and pay it, closing two cycles from two identical requests.
  test "a repeated full settle does not pay the following cycle" do
    series = declare_capped_bill(amount: 2000)

    first = Assistant::Function::RecordBillPayment.new(@user).call("bill_id" => series.id)
    second = Assistant::Function::RecordBillPayment.new(@user).call("bill_id" => series.id)

    assert first[:recorded]
    assert second[:error].present?, "nothing is owed once the due cycle is settled"
    assert_match(/pay ahead/, second[:hint])
    assert_equal 1, series.recurring_occurrences.where(status: "paid").count
  end

  test "paying ahead still works when the cycle is named" do
    series = declare_capped_bill(amount: 2000)
    Assistant::Function::RecordBillPayment.new(@user).call("bill_id" => series.id)
    future = series.recurring_occurrences.open_status.order(:due_on).first

    result = Assistant::Function::RecordBillPayment.new(@user).call("bill_id" => series.id, "occurrence_due_on" => future.due_on.iso8601)

    assert result[:recorded], "naming the date is the deliberate act a retry never performs"
  end

  test "non-finite and negative amounts are refused instead of coerced" do
    series = declare_capped_bill(amount: 2000)

    %w[Infinity NaN].each do |value|
      result = Assistant::Function::RecordBillPayment.new(@user).call("bill_id" => series.id, "amount" => value)
      assert_equal "amount is not a number", result[:error]
    end

    negative = Assistant::Function::RecordBillPayment.new(@user).call("bill_id" => series.id, "amount" => -500)
    assert_equal "amount must be greater than zero", negative[:error],
      "a negative used to be flipped with .abs and recorded as a payment"

    assert_equal 0, series.recurring_occurrences.order(:due_on).first.allocations.count
  end

  # "" is not "no amount": a present-but-blank value used to skip the amount
  # branch entirely and settle the whole occurrence.
  test "a blank amount is malformed input, not a settlement" do
    series = declare_capped_bill(amount: 100)

    result = Assistant::Function::RecordBillPayment.new(@user).call("bill_id" => series.id, "amount" => "")

    assert_match(/not a number/, result[:error])
    assert_equal 0, series.recurring_occurrences.order(:due_on).first.allocations.count
  end

  test "a read-only account share cannot record payments" do
    series = declare_capped_bill(amount: 100)
    series.update!(account: accounts(:credit_card))
    member = users(:family_member)

    result = Assistant::Function::RecordBillPayment.new(member).call("bill_id" => series.id)

    assert_match(/read-only/, result[:error])
    assert_equal 0, series.recurring_occurrences.order(:due_on).first.allocations.count
  end

  private

    def declare_capped_bill(amount:)
      due = Date.current
      series = @family.recurring_transactions.create!(
        name: "Rent #{amount}", account: accounts(:depository), amount: amount,
        currency: "USD", status: "active", bill_type: "bill", manual: true,
        dedup_scope: "rent-#{amount}", expected_day_of_month: due.day,
        last_occurrence_date: 1.month.ago.to_date, next_expected_date: due
      )
      series.recurring_occurrences.destroy_all
      series.recurring_occurrences.create!(
        family: @family, original_due_on: due, due_on: due,
        currency: "USD", expected_amount: amount, status: "scheduled"
      )
      series.recurring_occurrences.create!(
        family: @family, original_due_on: due + 30, due_on: due + 30,
        currency: "USD", expected_amount: amount, status: "scheduled"
      )
      series.reload
    end

    def call_tool(params)
      Assistant::Function::RecordBillPayment.new(@user).call({ "bill_id" => @series.id.to_s }.merge(params))
    end
end
