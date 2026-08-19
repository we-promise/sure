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

  private

    def call_tool(params)
      Assistant::Function::CreateBill.new(@user).call(params)
    end
end
