require "test_helper"

class Assistant::Function::CreateBillTest < ActiveSupport::TestCase
  setup do
    @user = users(:family_admin)
    @family = @user.family
    @family.recurring_transactions.destroy_all
  end

  test "creates a declared bill with schedule and upcoming dates" do
    due = Date.current.beginning_of_month.next_month + 8.days

    result = call_tool(
      "name" => "City Water", "amount" => 80, "first_due_on" => due.iso8601,
      "account_name" => accounts(:depository).name, "bill_type" => "subscription"
    )

    assert result[:created]
    assert_equal "City Water", result[:bill][:name]
    assert_equal "subscription", result[:bill][:bill_type]
    assert_equal 3, result[:upcoming_due_dates].size

    series = @family.recurring_transactions.find_by!(name: "City Water")
    assert series.manual?, "an AI-created bill is a declared bill"
    assert_equal accounts(:depository).id, series.account_id
    assert_operator series.recurring_occurrences.count, :>, 0
  end

  test "frequency once creates a single occurrence on the due date" do
    due = Date.current + 40

    result = call_tool(
      "name" => "Domain renewal", "amount" => 18, "first_due_on" => due.iso8601,
      "frequency" => "once"
    )

    assert result[:created]
    assert_equal [ due.iso8601 ], result[:upcoming_due_dates]

    series = @family.recurring_transactions.find_by!(name: "Domain renewal")
    assert series.one_off?
    assert_equal [ due ], series.recurring_occurrences.pluck(:due_on)
  end

  test "a bank reference is stored on the new bill" do
    result = call_tool(
      "name" => "City Water", "amount" => 80, "first_due_on" => (Date.current + 3).iso8601,
      "account_name" => accounts(:depository).name, "bank_reference" => "VN 4711"
    )

    assert result[:created]
    assert_equal "VN 4711", @family.recurring_transactions.find_by!(name: "City Water").bank_reference
  end

  test "reference_only is stored with the reference" do
    result = call_tool(
      "name" => "City Water", "amount" => 80, "first_due_on" => (Date.current + 3).iso8601,
      "account_name" => accounts(:depository).name, "bank_reference" => "VN 4711", "reference_only" => true
    )

    assert result[:created]
    assert @family.recurring_transactions.find_by!(name: "City Water").reference_only?
  end

  test "income flips the stored sign, never the caller's" do
    result = call_tool(
      "name" => "Paycheck", "amount" => 1200,
      "first_due_on" => (Date.current + 3).iso8601, "is_income" => true
    )

    assert result[:created]
    series = @family.recurring_transactions.find_by!(name: "Paycheck")
    assert series.amount.negative?, "income is stored negative"
    assert_equal "income", series.bill_type
  end

  test "an unknown account name returns a hint instead of guessing" do
    result = call_tool(
      "name" => "Bill", "amount" => 10, "first_due_on" => Date.current.iso8601,
      "account_name" => "No Such Account"
    )

    assert_match(/No account named/, result[:error])
    assert_includes result[:hint], "get_accounts"
    assert_equal 0, @family.recurring_transactions.count
  end

  test "another family's category can never be attached" do
    foreign = families(:empty).categories.create!(name: "Foreign category", color: "#ff0000")

    result = call_tool(
      "name" => "Bill", "amount" => 10, "first_due_on" => Date.current.iso8601,
      "category_name" => foreign.name
    )

    assert_match(/No category named/, result[:error],
      "a category outside the family must resolve to nothing")
    assert_equal 0, @family.recurring_transactions.count
  end

  test "a duplicate identity lands as a second tier via the dedup retry" do
    2.times do |i|
      result = call_tool(
        "name" => "Streaming Co", "amount" => 15.99 + i,
        "first_due_on" => Date.current.iso8601,
        "account_name" => accounts(:depository).name
      )
      assert result[:created], "attempt #{i + 1} must save"
    end

    assert_equal 2, @family.recurring_transactions.where(name: "Streaming Co").count
  end

  test "an invalid date returns the validation message as an error" do
    result = call_tool("name" => "Bill", "amount" => 10, "first_due_on" => "not-a-date")

    assert result[:error].present?
    assert result[:hint].present?
  end

  test "a non-numeric amount returns an error instead of raising" do
    result = call_tool("name" => "Bill", "amount" => "abc", "first_due_on" => (Date.current + 5).iso8601)

    assert result[:error].present?
    assert result[:hint].present?
    assert_not @family.recurring_transactions.exists?(name: "Bill")
  end


  # Every dedup index is keyed on account_id, and Postgres treats NULLs as
  # distinct, so an account-less bill collided with nothing and an LLM retry
  # doubled the family's recurring commitments.
  test "an account-less bill is not duplicated by a retry" do
    args = { "name" => "Netflix", "amount" => 15.99, "first_due_on" => (Date.current + 3).iso8601 }

    first = call_tool(args)
    second = call_tool(args)

    assert first[:created]
    assert second[:error].present?, "the retry must be recognized as the same bill"
    assert_equal 1, @family.recurring_transactions.where(name: "Netflix").count
  end

  test "a different amount is still a distinct account-less bill" do
    call_tool("name" => "Netflix", "amount" => 15.99, "first_due_on" => (Date.current + 3).iso8601)
    second = call_tool("name" => "Netflix", "amount" => 24.99, "first_due_on" => (Date.current + 3).iso8601)

    assert second[:created], "a price tier is a real second row, not a duplicate"
    assert_equal 2, @family.recurring_transactions.where(name: "Netflix").count
  end

  # "annual" is the enum word; "yearly" is the equally natural thing a model
  # says. It used to fall back to monthly, turning a $600 premium into a $600
  # monthly obligation.
  test "an unrecognized frequency is refused rather than made monthly" do
    result = call_tool("name" => "Insurance", "amount" => 600, "first_due_on" => (Date.current + 3).iso8601, "frequency" => "yearly")

    assert result[:error].present?
    assert_match(/not a frequency/, result[:error])
    assert_match(/annual/, result[:hint], "the hint has to name the word that works")
    assert_equal 0, @family.recurring_transactions.where(name: "Insurance").count
  end

  test "a recognized frequency still applies" do
    result = call_tool("name" => "Insurance", "amount" => 600, "first_due_on" => (Date.current + 3).iso8601, "frequency" => "annual")

    assert result[:created]
    series = @family.recurring_transactions.find_by(name: "Insurance")
    assert_equal "annual", RecurringTransaction::FrequencyPreset.detect(series).key
  end

  # The tool caller does not enforce params_schema: a loose MCP client can
  # send booleans as strings, and "true" == true is false in Ruby, which used
  # to silently declare a paycheck as a bill.
  test "boolean-ish strings cast and garbage booleans are refused" do
    result = call_tool("name" => "Paycheck", "amount" => 1200,
                       "first_due_on" => (Date.current + 3).iso8601, "is_income" => "true")

    assert result[:created]
    assert @family.recurring_transactions.find_by(name: "Paycheck").amount.negative?,
      "a string true must still declare income, stored negative"

    garbage = call_tool("name" => "Maybe", "amount" => 10,
                        "first_due_on" => (Date.current + 3).iso8601, "is_income" => "yeah")
    assert_match(/must be true or false/, garbage[:error])
    assert_nil @family.recurring_transactions.find_by(name: "Maybe")
  end

  test "a custom cadence repeats every 3 weeks from its anchor" do
    travel_to Date.new(2026, 11, 23) do
      result = call_tool("name" => "Hairdresser", "amount" => 30, "anchor_date" => "2026-11-24",
                         "frequency" => "custom", "interval_count" => 3, "interval_unit" => "week")

      assert result[:created], result[:error]
      assert_equal %w[2026-11-24 2026-12-15 2027-01-05], result[:upcoming_due_dates]
      assert_equal({ frequency: "custom", interval_count: 3, interval_unit: "week" },
                   result[:bill].slice(:frequency, :interval_count, :interval_unit))

      series = @family.recurring_transactions.find_by!(name: "Hairdresser")
      assert_equal Date.new(2026, 11, 24), series.anchor_date
      assert_equal [ Date.new(2026, 11, 24), Date.new(2026, 12, 15), Date.new(2027, 1, 5) ],
                   series.recurring_occurrences.order(:due_on).limit(3).pluck(:due_on)
    end
  end

  test "a custom count of days is stored in whole weeks, and refused otherwise" do
    travel_to Date.new(2026, 11, 23) do
      result = call_tool("name" => "Hairdresser", "amount" => 30, "first_due_on" => "2026-11-24",
                         "frequency" => "custom", "interval_count" => 21, "interval_unit" => "day")

      assert result[:created], result[:error]
      assert_equal [ 3, "week" ], result[:bill].values_at(:interval_count, :interval_unit)

      refused = call_tool("name" => "Pills", "amount" => 8, "first_due_on" => "2026-11-24",
                          "frequency" => "custom", "interval_count" => 10, "interval_unit" => "day")

      assert_match(/Every 10 days/, refused[:error])
      assert_nil @family.recurring_transactions.find_by(name: "Pills")
    end
  end

  test "interval fields are refused unless frequency is custom" do
    result = call_tool("name" => "Gym", "amount" => 40, "first_due_on" => (Date.current + 3).iso8601,
                       "frequency" => "weekly", "interval_count" => 3, "interval_unit" => "week")

    assert_match(/only apply to frequency custom/, result[:error])
    assert_nil @family.recurring_transactions.find_by(name: "Gym")

    missing = call_tool("name" => "Gym", "amount" => 40, "first_due_on" => (Date.current + 3).iso8601,
                        "frequency" => "custom", "interval_unit" => "week")

    assert_match(/needs interval_count/, missing[:error])
  end

  test "anchor_date and first_due_on name the same date and must agree" do
    result = call_tool("name" => "Gym", "amount" => 40, "first_due_on" => "2026-12-01", "anchor_date" => "2026-12-02")

    assert_match(/different dates/, result[:error])
    assert_nil @family.recurring_transactions.find_by(name: "Gym")

    invalid = call_tool("name" => "Gym", "amount" => 40, "anchor_date" => "next tuesday")

    assert_equal "anchor_date is not a valid date", invalid[:error]
  end

  test "a read-only shared account is not a creation destination" do
    member = users(:family_member)

    result = Assistant::Function::CreateBill.new(member).call(
      "name" => "Sneaky", "amount" => 10, "first_due_on" => (Date.current + 3).iso8601,
      "account_name" => accounts(:credit_card).name
    )

    assert_match(/add bills to/, result[:error])
    assert_nil @family.recurring_transactions.find_by(name: "Sneaky")
  end

  private

    def call_tool(params)
      Assistant::Function::CreateBill.new(@user).call(params)
    end
end
