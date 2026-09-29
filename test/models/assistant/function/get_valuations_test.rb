require "test_helper"

class Assistant::Function::GetValuationsTest < ActiveSupport::TestCase
  setup do
    @user = users(:family_admin)
    @family = @user.family
    @account = @family.accounts.visible.first
    @fn = Assistant::Function::GetValuations.new(@user)

    @entry = @account.entries.create!(
      name: "Manual valuation",
      date: Date.current,
      amount: 12_345,
      currency: @account.currency,
      notes: "statement 2026-07 (grade: A)",
      entryable: Valuation.new(kind: "reconciliation")
    )
  end

  test "has correct name" do
    assert_equal "get_valuations", @fn.name
  end

  test "is not in strict mode" do
    refute @fn.to_definition[:strict]
  end

  test "lists valuations with kind and provenance notes" do
    result = @fn.call

    row = result[:valuations].find { |v| v[:entry_id] == @entry.id }

    assert_not_nil row
    assert_equal "reconciliation", row[:kind]
    assert_equal "statement 2026-07 (grade: A)", row[:notes]
    assert_equal @account.id, row[:account][:id]
  end

  test "filters by account_id and validates its format" do
    result = @fn.call("account_id" => @account.id)

    assert result[:valuations].all? { |v| v[:account][:id] == @account.id }

    invalid = @fn.call("account_id" => "not-a-uuid")

    assert_equal "invalid_account_id", invalid[:error]
  end

  test "filters by date range" do
    result = @fn.call("start_date" => Date.current.to_s, "end_date" => Date.current.to_s)

    assert_includes result[:valuations].map { |v| v[:entry_id] }, @entry.id

    earlier = @fn.call("end_date" => 1.year.ago.to_date.to_s)

    assert_not_includes earlier[:valuations].map { |v| v[:entry_id] }, @entry.id
  end

  test "malformed dates fail loudly instead of silently dropping the filter" do
    result = @fn.call("start_date" => "not-a-date")

    assert_equal "invalid_date", result[:error]
  end

  test "a reversed date range returns the structured error" do
    result = @fn.call("start_date" => Date.current.to_s, "end_date" => 1.year.ago.to_date.to_s)

    assert_equal "invalid_date", result[:error]
  end

  test "invalid page numbers normalize to the first page" do
    result = @fn.call("page" => 0)

    assert_equal 1, result[:page]
    assert_includes result[:valuations].map { |v| v[:entry_id] }, @entry.id
  end

  test "excludes valuations on accounts the user cannot access" do
    member_fn = Assistant::Function::GetValuations.new(users(:family_member))
    investment_entry = accounts(:investment).entries.create!(
      name: "Hidden valuation",
      date: Date.current,
      amount: 999,
      currency: "USD",
      entryable: Valuation.new(kind: "reconciliation")
    )

    result = member_fn.call

    assert_not_includes result[:valuations].map { |v| v[:entry_id] }, investment_entry.id
  end
end
