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

  # Reported from live use: "What am I paying monthly for subscriptions?" answered
  # "No active subscriptions found, total monthly equivalent $0" while five
  # detected subscriptions sat in `suggested`. The status filter was right; the
  # silence about what it filtered out was the bug.
  test "an empty status-filtered result says where the matches actually are" do
    create_series(name: "Crunchyroll", amount: 12, status: "suggested", bill_type: "subscription", manual: false)
    create_series(name: "Huntr", amount: 40, status: "suggested", bill_type: "subscription", manual: false)

    result = call_tool("bill_type" => "subscription")

    assert_equal 0, result[:total_results]
    assert result[:hint].present?, "an empty result must say what other statuses hold"
    assert_match(/2 suggested/, result[:hint])
    assert_match(/status: all/, result[:hint])
  end

  test "the hint counts only the requested bill type" do
    create_series(name: "Crunchyroll", amount: 12, status: "suggested", bill_type: "subscription", manual: false)
    create_series(name: "Rent", amount: 2000, status: "suggested", bill_type: "bill", manual: false)

    result = call_tool("bill_type" => "subscription")

    assert_equal 0, result[:total_results]
    assert_match(/1 suggested/, result[:hint])
  end

  test "no hint when results are found" do
    create_series(name: "Crunchyroll", amount: 12, bill_type: "subscription")

    result = call_tool("bill_type" => "subscription")

    assert_operator result[:total_results], :>, 0
    assert_nil result[:hint]
  end

  test "no hint when the caller already asked for every status" do
    create_series(name: "Rent", amount: 2000, status: "suggested", bill_type: "bill", manual: false)

    result = call_tool("status" => "all", "bill_type" => "subscription")

    assert_equal 0, result[:total_results]
    assert_nil result[:hint], "status: all already saw everything, so there is nowhere else to point"
  end


  # strict_mode? is false and MCP bypasses provider validation, so out-of-schema
  # values arrive routinely. Each one used to fail silently and differently.
  test "an unknown bill_type is refused rather than dropping the filter" do
    create_series(name: "Rent", amount: 2000)
    create_series(name: "Netflix", amount: 12, bill_type: "subscription")

    result = call_tool("bill_type" => "subscriptions")

    assert_match(/not a valid bill_type/, result[:error],
      "plural used to drop the filter and total rent as a subscription")
    assert_nil result[:bills]
  end

  test "an unknown status is refused rather than silently meaning active" do
    create_series(name: "Rent", amount: 2000)

    result = call_tool("status" => "inactive")

    assert_match(/not a valid status/, result[:error])
    assert_match(/paused/, result[:hint], "the hint has to name the word that works")
  end

  test "an unknown payment_state is refused rather than matching nothing" do
    create_series(name: "Rent", amount: 2000)

    result = call_tool("payment_state" => "unpaid")

    assert_match(/not a valid payment_state/, result[:error])
  end

  test "valid filters still work" do
    create_series(name: "Netflix", amount: 12, bill_type: "subscription")

    result = call_tool("bill_type" => "subscription")

    assert_equal 1, result[:total_results]
  end

  # The hint can only redirect a status filter. Blaming status for a result
  # emptied by payment_state sent the model to the suggestion queue while it
  # was asking about overdue bills, and the retry it prescribed returned empty
  # again with no hint at all.
  test "the empty-result hint stays quiet when another filter did the emptying" do
    create_series(name: "Rent", amount: 2000)
    create_series(name: "Detected", amount: 9, status: "suggested", manual: false)

    result = call_tool("payment_state" => "overdue")

    assert_equal 0, result[:total_results]
    assert_nil result[:hint], "nothing about the suggested series explains an overdue query"
  end

  test "the hint still fires when status alone emptied the result" do
    create_series(name: "Detected", amount: 9, status: "suggested", manual: false)

    result = call_tool({})

    assert_equal 0, result[:total_results]
    assert_match(/suggested/, result[:hint])
  end

  # A filter that silently answers a different question than it was asked is
  # worse than an error: due_within_days: 0 used to clamp to 1.
  test "an out-of-range due_within_days is rejected, not silently adjusted" do
    create_series(name: "Rent", amount: 2150)

    assert_match(/between 1 and 365/, call_tool("due_within_days" => 0)[:error])
    assert_match(/between 1 and 365/, call_tool("due_within_days" => "soon")[:error])
    assert_match(/between 1 and 365/, call_tool("due_within_days" => 400)[:error])
    assert_nil call_tool("due_within_days" => 30)[:error]
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
