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

  test "accepts base64 wrapped across lines" do
    wrapped = Base64.strict_encode64(@content).scan(/.{1,8}/).join("\n")

    result = @function.call("filename" => "statement.csv", "content_base64" => wrapped)

    assert result[:success]
    assert_equal Digest::SHA256.hexdigest(@content), result[:statement][:content_sha256]
  end

  test "accepts urlsafe base64 without padding" do
    # Chosen so the encoding actually uses the URL-safe alphabet; the usual
    # fixture encodes to plain base64, which would exercise the padding branch
    # while leaving the "-_" translation untested.
    content = "a,b\n1,2\n~~~???\n"
    encoded = Base64.urlsafe_encode64(content, padding: false)
    assert_match(/-/, encoded, "fixture must exercise the urlsafe alphabet")
    assert_match(/_/, encoded, "fixture must exercise the urlsafe alphabet")
    assert_no_match(/=/, encoded, "fixture must be unpadded")

    result = @function.call("filename" => "statement.csv", "content_base64" => encoded)

    assert result[:success]
    assert_equal Digest::SHA256.hexdigest(content), result[:statement][:content_sha256]
  end

  test "rejects blank content" do
    # Base64.strict_encode64("") is "", which is blank, so this never reaches
    # the decoder — hence invalid_content rather than empty_file.
    result = @function.call("filename" => "statement.csv", "content_base64" => Base64.strict_encode64(""))

    assert_not result[:success]
    assert_equal "invalid_content", result[:error]
  end

  test "reports an unexpected storage failure without leaking the exception" do
    AccountStatement.stubs(:create_from_prepared_upload!).raises(StandardError, "s3://bucket/secret-key exploded")

    result = @function.call(params(filename: "statement.csv"))

    assert_not result[:success]
    assert_equal "upload_failed", result[:error]
    # The response crosses out to an external agent, so it must carry none of
    # the exception's detail.
    assert_no_match(/s3:|bucket|secret-key|exploded/, result[:message])
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
