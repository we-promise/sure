require "test_helper"

class Assistant::Function::UploadAccountStatementTest < ActiveSupport::TestCase
  setup do
    @user = users(:family_admin)
    @account = accounts(:depository)
    @function = Assistant::Function::UploadAccountStatement.new(@user)
    @content = "date,amount\n2024-01-01,1\n"
  end

  test "has correct name and is not strict" do
    assert_equal "upload_account_statement", @function.name
    assert_not @function.strict_mode?
    assert_includes @function.params_schema[:required], "content_base64"
  end

  test "stores a statement in the vault" do
    result = nil

    assert_difference "AccountStatement.count", 1 do
      result = @function.call(params(filename: "statement.csv"))
    end

    assert result[:success]
    assert_not result[:duplicate]
    assert_equal Digest::SHA256.hexdigest(@content), result[:statement][:content_sha256]
    assert_equal "statement.csv", result[:statement][:filename]
  end

  test "re-uploading identical bytes returns the existing statement without creating a row" do
    first = @function.call(params(filename: "statement.csv"))

    assert_no_difference "AccountStatement.count" do
      second = @function.call(params(filename: "different-name.csv"))

      assert second[:success]
      assert second[:duplicate]
      assert_equal first[:statement][:id], second[:statement][:id]
    end
  end

  test "links to an account when one is given" do
    result = @function.call(params(filename: "statement.csv", account_id: @account.id))

    assert result[:success]
    assert_equal @account.id, result[:statement][:account][:id]
    assert_equal "linked", result[:statement][:review_status]
  end

  test "leaves the statement unmatched when no account is given" do
    result = @function.call(params(filename: "statement.csv"))

    assert_equal "unmatched", result[:statement][:review_status]
    assert_nil result[:statement][:account]
  end

  test "reports a duplicate without disclosing a statement filed against a hidden account" do
    @function.call(params(filename: "statement.csv", account_id: accounts(:other_asset).id))

    result = Assistant::Function::UploadAccountStatement.new(users(:family_member))
      .call(params(filename: "statement.csv"))

    assert result[:success]
    assert result[:duplicate]
    assert_equal Digest::SHA256.hexdigest(@content), result[:statement][:content_sha256]
    assert_nil result[:statement][:account]
    assert_nil result[:statement][:filename]
  end

  test "refuses a user who cannot manage the vault" do
    result = Assistant::Function::UploadAccountStatement.new(family_guest).call(params(filename: "statement.csv"))

    assert_not result[:success]
    assert_equal "forbidden", result[:error]
  end

  test "rejects an unsupported file type" do
    result = @function.call(params(filename: "notes.txt"))

    assert_not result[:success]
    assert_equal "unsupported_file_type", result[:error]
  end

  test "rejects content that is not base64" do
    result = @function.call("filename" => "statement.csv", "content_base64" => "not base64 @@@")

    assert_not result[:success]
    assert_equal "invalid_content", result[:error]
  end

  test "rejects an unknown account_id rather than silently uploading unlinked" do
    result = @function.call(params(filename: "statement.csv", account_id: SecureRandom.uuid))

    assert_not result[:success]
    assert_equal "account_not_found", result[:error]
  end

  test "rejects a file whose contents do not match its extension" do
    result = @function.call(
      "filename" => "statement.pdf",
      "content_base64" => Base64.strict_encode64("this is not a pdf")
    )

    assert_not result[:success]
    assert_equal "invalid_file", result[:error]
  end

  private
    def params(filename:, account_id: nil, content: @content)
      { "filename" => filename, "content_base64" => Base64.strict_encode64(content) }.tap do |p|
        p["account_id"] = account_id if account_id
      end
    end
end
