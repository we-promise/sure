require "test_helper"

class AccountStatementsControllerTest < ActionDispatch::IntegrationTest
  setup do
    ensure_tailwind_build
    sign_in @user = users(:family_admin)
    @account = accounts(:depository)
  end

  test "shows statement vault" do
    get account_statements_url
    assert_response :success
    assert_select "h1", text: "Statement vault"
  end

  test "uploads statement to account without importing transactions" do
    assert_difference "AccountStatement.count", 1 do
      assert_no_difference [ "Import.count", "Entry.count", "Transaction.count" ] do
        post account_statements_url, params: {
          account_statement: {
            account_id: @account.id,
            files: [ uploaded_file(filename: "Checking_2024-01.csv", content_type: "text/csv") ]
          }
        }
      end
    end

    statement = AccountStatement.order(:created_at).last
    assert_equal @account, statement.account
    assert statement.linked?
    assert_redirected_to account_url(@account, tab: "statements")
  end

  test "uploads unmatched statement to inbox" do
    assert_difference "AccountStatement.count", 1 do
      post account_statements_url, params: {
        account_statement: {
          files: [ uploaded_file(filename: "Unknown_2024-01.csv", content_type: "text/csv") ]
        }
      }
    end

    statement = AccountStatement.order(:created_at).last
    assert_nil statement.account
    assert statement.unmatched?
    assert_redirected_to account_statement_url(statement)
  end

  test "skips duplicate statement upload" do
    AccountStatement.create_from_upload!(
      family: @account.family,
      account: @account,
      file: uploaded_file(filename: "statement.csv", content_type: "text/csv", content: "date,amount\n2024-01-01,1\n")
    )

    assert_no_difference "AccountStatement.count" do
      post account_statements_url, params: {
        account_statement: {
          account_id: @account.id,
          files: [ uploaded_file(filename: "duplicate.csv", content_type: "text/csv", content: "date,amount\n2024-01-01,1\n") ]
        }
      }
    end

    assert_redirected_to account_url(@account, tab: "statements")
    assert_equal "1 duplicate statement was skipped.", flash[:alert]
  end

  test "rejects invalid statement file type" do
    assert_no_difference "AccountStatement.count" do
      post account_statements_url, params: {
        account_statement: {
          files: [ uploaded_file(filename: "statement.bin", content_type: "application/octet-stream", content: "\x00\x01\x02".b) ]
        }
      }
    end

    assert_redirected_to account_statements_url
    assert_equal "Upload a PDF, CSV, or XLSX statement under the size limit.", flash[:alert]
  end

  test "rejects oversized statement upload" do
    assert_no_difference "AccountStatement.count" do
      post account_statements_url, params: {
        account_statement: {
          files: [
            uploaded_file(
              filename: "oversized.csv",
              content_type: "text/csv",
              content: "x" * (AccountStatement::MAX_FILE_SIZE + 1)
            )
          ]
        }
      }
    end

    assert_redirected_to account_statements_url
    assert_equal "Upload a PDF, CSV, or XLSX statement under the size limit.", flash[:alert]
  end

  test "rejects cross-family account id" do
    other_account = Account.create!(
      family: families(:empty),
      owner: users(:empty),
      name: "Other family account",
      balance: 0,
      currency: "USD",
      accountable: Depository.new
    )

    assert_no_difference "AccountStatement.count" do
      post account_statements_url, params: {
        account_statement: {
          account_id: other_account.id,
          files: [ uploaded_file(filename: "statement.csv", content_type: "text/csv") ]
        }
      }
    end
    assert_response :not_found
  end

  test "read only shared user cannot upload to account" do
    sign_in users(:family_member)
    account = accounts(:credit_card)

    assert_no_difference "AccountStatement.count" do
      post account_statements_url, params: {
        account_statement: {
          account_id: account.id,
          files: [ uploaded_file(filename: "statement.csv", content_type: "text/csv") ]
        }
      }
    end

    assert_redirected_to account_url(account)
    assert_equal "You don't have permission to manage this account", flash[:alert]
  end

  test "links suggested statement" do
    statement = AccountStatement.create_from_upload!(
      family: @account.family,
      account: nil,
      file: uploaded_file(filename: "statement.csv", content_type: "text/csv", content: "date,amount\n2024-01-01,1\n")
    )
    statement.update!(suggested_account: @account, match_confidence: 0.9)

    patch link_account_statement_url(statement), params: { account_id: @account.id }

    assert_redirected_to account_url(@account, tab: "statements")
    statement.reload
    assert_equal @account, statement.account
    assert statement.linked?
  end

  test "unlinks statement back to inbox" do
    statement = AccountStatement.create_from_upload!(
      family: @account.family,
      account: @account,
      file: uploaded_file(filename: "statement.csv", content_type: "text/csv", content: "date,amount\n2024-01-01,1\n")
    )

    patch unlink_account_statement_url(statement)

    assert_redirected_to account_statement_url(statement)
    statement.reload
    assert_nil statement.account
    assert statement.unmatched?
  end

  test "rejects suggestion" do
    statement = AccountStatement.create_from_upload!(
      family: @account.family,
      account: nil,
      file: uploaded_file(filename: "statement.csv", content_type: "text/csv", content: "date,amount\n2024-01-01,1\n")
    )
    statement.update!(suggested_account: @account, match_confidence: 0.9)

    patch reject_account_statement_url(statement)

    assert_redirected_to account_statements_url
    statement.reload
    assert statement.rejected?
    assert_nil statement.suggested_account
  end

  test "updates metadata" do
    statement = AccountStatement.create_from_upload!(
      family: @account.family,
      account: @account,
      file: uploaded_file(filename: "statement.csv", content_type: "text/csv", content: "date,amount\n2024-01-01,1\n")
    )

    patch account_statement_url(statement), params: {
      account_statement: {
        period_start_on: "2024-01-01",
        period_end_on: "2024-01-31",
        closing_balance: "123.45",
        currency: "usd"
      }
    }

    assert_redirected_to account_statement_url(statement)
    statement.reload
    assert_equal Date.new(2024, 1, 31), statement.period_end_on
    assert_equal 123.45.to_d, statement.closing_balance
    assert_equal "USD", statement.currency
  end

  test "metadata update links selected account" do
    statement = AccountStatement.create_from_upload!(
      family: @account.family,
      account: nil,
      file: uploaded_file(filename: "statement.csv", content_type: "text/csv", content: "date,amount\n2024-01-01,1\n")
    )

    patch account_statement_url(statement), params: {
      account_statement: {
        account_id: @account.id,
        period_start_on: "2024-01-01",
        period_end_on: "2024-01-31"
      }
    }

    assert_redirected_to account_statement_url(statement)
    statement.reload
    assert_equal @account, statement.account
    assert statement.linked?
  end

  test "deletes statement" do
    statement = AccountStatement.create_from_upload!(
      family: @account.family,
      account: @account,
      file: uploaded_file(filename: "statement.csv", content_type: "text/csv", content: "date,amount\n2024-01-01,1\n")
    )

    assert_difference "AccountStatement.count", -1 do
      delete account_statement_url(statement)
    end

    assert_redirected_to account_url(@account, tab: "statements")
  end

  private

    def uploaded_file(filename:, content_type:, content: "date,amount\n2024-01-01,1\n")
      tempfile = Tempfile.new([ File.basename(filename, ".*"), File.extname(filename) ])
      tempfile.binmode
      tempfile.write(content)
      tempfile.rewind

      Rack::Test::UploadedFile.new(tempfile.path, content_type, true, original_filename: filename)
    end
end
