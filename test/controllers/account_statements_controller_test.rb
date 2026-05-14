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
    assert_select "h1", text: I18n.t("account_statements.index.title")
  end

  test "statement vault only lists linked statements for accessible accounts" do
    accessible_statement = AccountStatement.create_from_upload!(
      family: @account.family,
      account: @account,
      file: uploaded_file(filename: "accessible_statement.csv", content_type: "text/csv", content: "date,amount\n2024-01-01,1\n")
    )
    private_account = accounts(:other_asset)
    private_statement = AccountStatement.create_from_upload!(
      family: private_account.family,
      account: private_account,
      file: uploaded_file(filename: "private_statement.csv", content_type: "text/csv", content: "date,amount\n2024-01-02,2\n")
    )
    sign_in users(:family_member)

    get account_statements_url

    assert_response :success
    assert_includes response.body, accessible_statement.filename
    refute_includes response.body, private_statement.filename
    refute_includes response.body, private_account.name
  end

  test "non manager cannot open statement vault" do
    sign_in family_guest

    get account_statements_url

    assert_redirected_to accounts_url
    assert_equal I18n.t("accounts.not_authorized"), flash[:alert]
  end

  test "non manager cannot view unmatched statement" do
    statement = AccountStatement.create_from_upload!(
      family: @account.family,
      account: nil,
      file: uploaded_file(filename: "statement.csv", content_type: "text/csv")
    )
    sign_in family_guest

    get account_statement_url(statement)

    assert_response :not_found
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

  test "member with writable account access can upload linked statement" do
    sign_in users(:family_member)

    assert_difference "AccountStatement.count", 1 do
      post account_statements_url, params: {
        account_statement: {
          account_id: @account.id,
          files: [ uploaded_file(filename: "member_statement.csv", content_type: "text/csv") ]
        }
      }
    end

    statement = AccountStatement.order(:created_at).last
    assert_equal @account, statement.account
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
    assert_equal I18n.t("account_statements.create.duplicates", count: 1), flash[:alert]
  end

  test "continues upload loop after a validation error" do
    invalid_record = AccountStatement.new
    invalid_record.errors.add(:filename, "is invalid")

    assert_difference "AccountStatement.count", 1 do
      created_statement = AccountStatement.create_from_upload!(
        family: @account.family,
        account: @account,
        file: uploaded_file(filename: "valid-result.csv", content_type: "text/csv", content: "date,amount\n2024-01-02,2\n")
      )
      upload_sequence = sequence("statement upload processing")
      AccountStatement.expects(:create_from_prepared_upload!).in_sequence(upload_sequence).raises(ActiveRecord::RecordInvalid.new(invalid_record))
      AccountStatement.expects(:create_from_prepared_upload!).in_sequence(upload_sequence).returns(created_statement)

      post account_statements_url, params: {
        account_statement: {
          account_id: @account.id,
          files: [
            uploaded_file(filename: "invalid.csv", content_type: "text/csv", content: "date,amount\n2024-01-01,1\n"),
            uploaded_file(filename: "valid.csv", content_type: "text/csv", content: "date,amount\n2024-01-02,2\n")
          ]
        }
      }
    end

    assert_redirected_to account_url(@account, tab: "statements")
    assert_equal I18n.t("account_statements.create.success", count: 1), flash[:notice]
    assert_includes flash[:alert], invalid_record.errors.full_messages.to_sentence
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
    assert_equal I18n.t("account_statements.create.invalid_file_type"), flash[:alert]
  end

  test "continues upload loop after an invalid file type" do
    assert_difference "AccountStatement.count", 1 do
      post account_statements_url, params: {
        account_statement: {
          files: [
            uploaded_file(filename: "statement.bin", content_type: "application/octet-stream", content: "\x00\x01\x02".b),
            uploaded_file(filename: "valid.csv", content_type: "text/csv", content: "date,amount\n2024-01-02,2\n")
          ]
        }
      }
    end

    statement = AccountStatement.order(:created_at).last
    assert_redirected_to account_statement_url(statement)
    assert_equal I18n.t("account_statements.create.success", count: 1), flash[:notice]
    assert_includes flash[:alert], I18n.t("account_statements.create.invalid_file_type")
  end

  test "rejects txt and xls statement uploads" do
    [
      uploaded_file(filename: "statement.txt", content_type: "text/plain"),
      uploaded_file(filename: "statement.xls", content_type: "application/vnd.ms-excel")
    ].each do |file|
      assert_no_difference "AccountStatement.count" do
        post account_statements_url, params: {
          account_statement: {
            files: [ file ]
          }
        }
      end

      assert_redirected_to account_statements_url
      assert_equal I18n.t("account_statements.create.invalid_file_type"), flash[:alert]
    end
  end

  test "rejects empty csv and xlsx statement uploads" do
    [
      uploaded_file(filename: "empty.csv", content_type: "text/csv", content: ""),
      uploaded_file(
        filename: "empty.xlsx",
        content_type: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
        content: ""
      )
    ].each do |file|
      assert_no_difference "AccountStatement.count" do
        post account_statements_url, params: {
          account_statement: {
            files: [ file ]
          }
        }
      end

      assert_redirected_to account_statements_url
      assert_equal I18n.t("account_statements.create.invalid_file_type"), flash[:alert]
    end
  end

  test "rejects oversized statement upload" do
    original_max_file_size = AccountStatement::MAX_FILE_SIZE
    silence_warnings { AccountStatement.const_set(:MAX_FILE_SIZE, 16) }

    begin
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
    ensure
      silence_warnings { AccountStatement.const_set(:MAX_FILE_SIZE, original_max_file_size) }
    end

    assert_redirected_to account_statements_url
    assert_equal I18n.t("account_statements.create.invalid_file_type"), flash[:alert]
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
    assert_equal I18n.t("accounts.not_authorized"), flash[:alert]
  end

  test "read only shared user sees statement detail without edit controls" do
    account = accounts(:credit_card)
    statement = AccountStatement.create_from_upload!(
      family: @account.family,
      account: account,
      file: uploaded_file(filename: "readonly_statement.csv", content_type: "text/csv")
    )
    sign_in users(:family_member)

    get account_statement_url(statement)

    assert_response :success
    assert_select "input[name='account_statement[period_start_on]']", 0
    assert_select "select[name='account_statement[account_id]']", 0
    assert_select "button", text: I18n.t("account_statements.show.delete"), count: 0
    assert_select "button", text: I18n.t("account_statements.show.save"), count: 0
    assert_select "button", text: I18n.t("account_statements.show.unlink"), count: 0
  end

  test "metadata form does not expose account select for managers" do
    statement = AccountStatement.create_from_upload!(
      family: @account.family,
      account: @account,
      file: uploaded_file(filename: "manager_statement.csv", content_type: "text/csv")
    )

    get account_statement_url(statement)

    assert_response :success
    assert_select "input[name='account_statement[period_start_on]']", 1
    assert_select "input[name='account_statement[currency]']", 0
    assert_select "select[name='account_statement[currency]'] option[value='USD']"
    assert_select "select[name='account_statement[account_id]']", 0
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

  test "read only shared user cannot relink linked statement to writable account" do
    source_account = accounts(:credit_card)
    target_account = accounts(:depository)
    statement = AccountStatement.create_from_upload!(
      family: source_account.family,
      account: source_account,
      file: uploaded_file(filename: "readonly_relink.csv", content_type: "text/csv", content: "date,amount\n2024-01-01,1\n")
    )
    sign_in users(:family_member)

    patch link_account_statement_url(statement), params: { account_id: target_account.id }

    assert_redirected_to account_url(source_account)
    assert_equal I18n.t("accounts.not_authorized"), flash[:alert]
    assert_equal source_account, statement.reload.account
  end

  test "link shows friendly error when no target account is available" do
    statement = AccountStatement.create_from_upload!(
      family: @account.family,
      account: nil,
      file: uploaded_file(filename: "statement.csv", content_type: "text/csv", content: "date,amount\n2024-01-01,1\n")
    )

    patch link_account_statement_url(statement)

    assert_redirected_to account_statement_url(statement)
    assert_equal I18n.t("account_statements.link.no_account"), flash[:alert]
    statement.reload
    assert_nil statement.account
    assert statement.unmatched?
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

  test "destroy reports failure when statement cannot be deleted" do
    statement = AccountStatement.create_from_upload!(
      family: @account.family,
      account: @account,
      file: uploaded_file(filename: "statement.csv", content_type: "text/csv", content: "date,amount\n2024-01-01,1\n")
    )
    AccountStatement.any_instance.stubs(:destroy).returns(false)

    assert_no_difference "AccountStatement.count" do
      delete account_statement_url(statement)
    end

    assert_redirected_to account_url(@account, tab: "statements")
    assert_equal I18n.t("account_statements.destroy.failure"), flash[:alert]
  end
end
