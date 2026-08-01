require "test_helper"

class Assistant::Function::ListAccountStatementsTest < ActiveSupport::TestCase
  setup do
    @user = users(:family_admin)
    @account = accounts(:depository)
    @function = Assistant::Function::ListAccountStatements.new(@user)
  end

  test "lists statements with identity and provenance" do
    statement = create_statement(account: @account, content: "date,amount\n2024-01-01,1\n")

    result = @function.call

    assert result[:success]
    assert_equal 1, result[:returned]
    assert_not result[:has_more]
    payload = result[:statements].first
    assert_equal statement.id, payload[:id]
    assert_equal statement.content_sha256, payload[:content_sha256]
    assert_equal @account.id, payload[:account][:id]
  end

  test "filters by review status" do
    create_statement(account: @account, content: "date,amount\n2024-01-01,1\n")
    create_statement(account: nil, content: "date,amount\n2024-02-01,2\n")

    result = @function.call("review_status" => "unmatched")

    assert result[:success]
    assert_equal 1, result[:returned]
    assert_equal "unmatched", result[:statements].first[:review_status]
  end

  test "filters by content sha256" do
    statement = create_statement(account: @account, content: "date,amount\n2024-01-01,1\n")
    create_statement(account: @account, content: "date,amount\n2024-02-01,2\n")

    result = @function.call("content_sha256" => statement.content_sha256)

    assert_equal 1, result[:returned]
    assert_equal statement.id, result[:statements].first[:id]
  end

  test "finds a statement by uppercase sha256" do
    statement = create_statement(account: @account, content: "date,amount\n2024-01-01,1\n")

    result = @function.call("content_sha256" => statement.content_sha256.upcase)

    assert_equal 1, result[:returned]
    assert_equal statement.id, result[:statements].first[:id]
  end

  test "filters by overlapping period window" do
    statement = create_statement(account: @account, content: "date,amount\n2024-01-01,1\n")
    statement.update!(period_start_on: Date.new(2024, 3, 1), period_end_on: Date.new(2024, 3, 31))

    assert_equal 1, @function.call("overlapping_from" => "2024-03-15")[:returned]
    assert_equal 1, @function.call("overlapping_until" => "2024-03-15")[:returned]
    assert_equal 0, @function.call("overlapping_from" => "2024-04-01")[:returned]
    assert_equal 0, @function.call("overlapping_until" => "2024-02-01")[:returned]
  end

  test "rejects an invalid review status" do
    result = @function.call("review_status" => "whatever")

    assert_not result[:success]
    assert_equal "invalid_review_status", result[:error]
  end

  test "rejects an invalid date filter" do
    result = @function.call("overlapping_from" => "last tuesday")

    assert_not result[:success]
    assert_equal "invalid_date", result[:error]
  end

  test "hides statements linked to accounts the user cannot see" do
    private_account = accounts(:other_asset)
    create_statement(account: private_account, content: "date,amount\n2024-03-01,3\n")

    result = Assistant::Function::ListAccountStatements.new(users(:family_member)).call

    assert result[:success]
    assert_empty result[:statements]
  end

  test "refuses a user who cannot manage the vault" do
    result = Assistant::Function::ListAccountStatements.new(family_guest).call

    assert_not result[:success]
    assert_equal "forbidden", result[:error]
  end

  private
    def create_statement(account:, content:)
      AccountStatement.create_from_upload!(
        family: @user.family,
        account: account,
        file: uploaded_file(filename: "statement-#{Digest::MD5.hexdigest(content)}.csv", content_type: "text/csv", content: content)
      )
    end
end
