require "test_helper"

class Assistant::Function::GetBillsTest < ActiveSupport::TestCase
  setup do
    @user = users(:family_admin)
    @family = @user.family
    @family.recurring_transactions.destroy_all
  end

  test "defaults to active bills and hides review states" do
    create_series(name: "Active bill", amount: 50)
    create_series(name: "Suggested detection", amount: 20, status: "suggested", manual: false)
    create_series(name: "Dismissed", amount: 10, status: "ended")
    create_series(name: "Paused bill", amount: 30, status: "inactive")

    result = call_tool

    names = result[:bills].map { |bill| bill[:name] }
    assert_includes names, "Active bill"
    assert_not_includes names, "Suggested detection"
    assert_not_includes names, "Dismissed"
    assert_not_includes names, "Paused bill"
  end

  test "the paused filter speaks the UI vocabulary over the stored value" do
    create_series(name: "Paused bill", amount: 30, status: "inactive")

    result = call_tool("status" => "paused")

    row = result[:bills].sole
    assert_equal "Paused bill", row[:name]
    assert_equal "paused", row[:status], "stored 'inactive' must serialize as the UI's word"
  end

  test "payment_state filters on the current occurrence" do
    travel_to Date.current do
      overdue_day = 10.days.ago.to_date
      create_series(name: "Late bill", amount: 75,
                    expected_day_of_month: overdue_day.day,
                    anchor_date: overdue_day,
                    last_occurrence_date: 2.months.ago.to_date,
                    next_expected_date: overdue_day)
      # Anchored at its own future due date: the generator floors at anchor,
      # so no past-cycle row exists to read as overdue.
      future_day = Date.current + 10
      create_series(name: "Future bill", amount: 20,
                    expected_day_of_month: future_day.day,
                    anchor_date: future_day,
                    last_occurrence_date: future_day - 1.month,
                    next_expected_date: future_day)

      result = call_tool("payment_state" => "overdue")

      assert_equal [ "Late bill" ], result[:bills].map { |bill| bill[:name] }
    end
  end

  test "search matches the merchant behind a nameless series" do
    create_series(name: nil, merchant: merchants(:netflix), amount: 15.99)
    create_series(name: "Water", amount: 80)

    result = call_tool("search" => merchants(:netflix).name)

    assert_equal [ merchants(:netflix).name ], result[:bills].map { |bill| bill[:name] }
  end

  test "a member only sees bills on accounts they were given" do
    create_series(name: "Visible bill", amount: 10)
    create_series(name: "Hidden brokerage bill", amount: 99, account: accounts(:investment))

    result = Assistant::Function::GetBills.new(users(:family_member)).call({})

    names = result[:bills].map { |bill| bill[:name] }
    assert_includes names, "Visible bill"
    assert_not_includes names, "Hidden brokerage bill"
  end

  test "totals exclude income and transfers and count the overdue" do
    create_series(name: "Real bill", amount: 100)
    create_series(name: "Paycheck", amount: -2000, bill_type: "income")
    create_series(name: "Card payment", amount: 300, bill_type: "transfer",
                  destination_account_id: accounts(:credit_card).id)

    result = call_tool("status" => "all")

    monthly = result[:totals][:active_monthly_equivalent_by_currency].fetch("USD")
    assert_equal "$100.00", monthly, "income and transfers must not inflate the spend total"
  end

  test "a disabled family gets an error with a hint, not a raise" do
    @family.update!(recurring_transactions_disabled: true)

    result = call_tool

    assert_match(/disabled/, result[:error])
    assert result[:hint].present?
  end

  private

    def call_tool(params = {})
      Assistant::Function::GetBills.new(@user).call(params)
    end

    def create_series(name:, amount:, merchant: nil, account: accounts(:depository), **overrides)
      @family.recurring_transactions.create!({
        name: name,
        merchant: merchant,
        account: account,
        amount: amount,
        dedup_scope: "#{name}-#{amount}",
        currency: "USD",
        expected_day_of_month: Date.current.day,
        last_occurrence_date: 1.month.ago.to_date,
        next_expected_date: Date.current,
        status: "active",
        # The generator's anchor floor (no fabricated past debt) applies to
        # declared series, which is what these test rows stand in for.
        manual: true,
        bill_type: amount.to_d.negative? ? "income" : "bill"
      }.merge(overrides))
    end
end
