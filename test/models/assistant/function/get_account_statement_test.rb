require "test_helper"

class Assistant::Function::GetAccountStatementTest < ActiveSupport::TestCase
  setup do
    @user = users(:family_admin)
    @account = accounts(:depository)
    @function = Assistant::Function::GetAccountStatement.new(@user)
  end

  test "returns statement identity and reconciliation checks" do
    statement = create_statement(account: @account)
    statement.update!(
      period_start_on: Date.new(2024, 1, 1),
      period_end_on: Date.new(2024, 1, 31),
      opening_balance: 100,
      closing_balance: 200,
      currency: @account.currency
    )

    result = @function.call("statement_id" => statement.id)

    assert result[:success]
    assert_equal statement.id, result[:statement][:id]
    assert_equal statement.content_sha256, result[:statement][:content_sha256]
    assert_equal "2024-01-31", result[:statement][:period_end_on]
    assert result[:statement].key?(:reconciliation_checks)
  end

  test "returns not_found for an unknown id" do
    result = @function.call("statement_id" => SecureRandom.uuid)

    assert_not result[:success]
    assert_equal "not_found", result[:error]
  end

  test "returns not_found for a non-uuid id" do
    result = @function.call("statement_id" => "nope")

    assert_not result[:success]
    assert_equal "not_found", result[:error]
  end

  test "returns not_found for a statement the user cannot view" do
    statement = create_statement(account: accounts(:other_asset))

    result = Assistant::Function::GetAccountStatement.new(users(:family_member)).call("statement_id" => statement.id)

    assert_not result[:success]
    assert_equal "not_found", result[:error]
  end

  test "refuses a user who cannot manage the vault" do
    statement = create_statement(account: @account)

    result = Assistant::Function::GetAccountStatement.new(family_guest).call("statement_id" => statement.id)

    assert_not result[:success]
    assert_equal "forbidden", result[:error]
  end

  private
    def create_statement(account:)
      AccountStatement.create_from_upload!(
        family: @user.family,
        account: account,
        file: uploaded_file(
          filename: "statement-#{SecureRandom.hex(4)}.csv",
          content_type: "text/csv",
          content: "date,amount\n2024-01-01,#{SecureRandom.random_number(1000)}\n"
        )
      )
    end
end
