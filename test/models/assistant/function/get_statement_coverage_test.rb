require "test_helper"

class Assistant::Function::GetStatementCoverageTest < ActiveSupport::TestCase
  setup do
    @user = users(:family_admin)
    @account = accounts(:depository)
    @function = Assistant::Function::GetStatementCoverage.new(@user)
  end

  test "reports a covered month and the months with no statement on record" do
    # A full prior year: every month is inside the expected window, so the one
    # month with a statement is covered and the rest report as missing.
    january = Date.current.prev_year.beginning_of_year
    statement = AccountStatement.create_from_upload!(
      family: @user.family,
      account: @account,
      file: uploaded_file(filename: "statement.csv", content_type: "text/csv", content: "date,amount\n2024-01-01,1\n")
    )
    statement.update!(period_start_on: january, period_end_on: january.end_of_month)

    result = @function.call("account_id" => @account.id, "year" => january.year)

    assert result[:success]
    assert_equal @account.id, result[:account][:id]
    assert_equal january.year, result[:year]

    covered = result[:months].find { |m| m[:month] == january.strftime("%Y-%m") }
    assert_equal "covered", covered[:status]
    assert_includes covered[:statement_ids], statement.id

    february = result[:months].find { |m| m[:month] == january.next_month.strftime("%Y-%m") }
    assert_equal "missing", february[:status]
  end

  # "covered" means a document exists, not that it agrees with the ledger — an
  # unreconciled statement still counts as covered, so the month has to carry its
  # own reconciliation status or the agent cannot tell the two apart.
  test "a covered month reports unavailable reconciliation when no balances are entered" do
    january = Date.current.prev_year.beginning_of_year
    statement = AccountStatement.create_from_upload!(
      family: @user.family,
      account: @account,
      file: uploaded_file(filename: "unreconciled.csv", content_type: "text/csv", content: "date,amount\n2024-01-01,1\n")
    )
    statement.update!(period_start_on: january, period_end_on: january.end_of_month)

    result = @function.call("account_id" => @account.id, "year" => january.year)
    covered = result[:months].find { |m| m[:month] == january.strftime("%Y-%m") }

    assert_equal "covered", covered[:status]
    assert_equal "unavailable", covered[:reconciliation_status]
  end

  test "rejects a non-uuid account id" do
    result = @function.call("account_id" => "nope")

    assert_not result[:success]
    assert_equal "invalid_account_id", result[:error]
  end

  test "rejects an account the user cannot access" do
    result = Assistant::Function::GetStatementCoverage.new(users(:family_member))
      .call("account_id" => accounts(:other_asset).id)

    assert_not result[:success]
    assert_equal "account_not_found", result[:error]
  end

  test "refuses a user who cannot manage the vault" do
    result = Assistant::Function::GetStatementCoverage.new(family_guest).call("account_id" => @account.id)

    assert_not result[:success]
    assert_equal "forbidden", result[:error]
  end
end
