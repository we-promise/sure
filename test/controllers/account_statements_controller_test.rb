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

  test "statement balances keep their decimals in a whole-number currency" do
    statement = AccountStatement.create_from_upload!(
      family: @account.family,
      account: @account,
      file: uploaded_file(filename: "jpy_statement.csv", content_type: "text/csv")
    )
    statement.update_columns(currency: "JPY", opening_balance: BigDecimal("100.25"), closing_balance: BigDecimal("1500"))

    get account_statement_url(statement)

    assert_response :success
    assert_select "input[name='account_statement[opening_balance]'][value='100.25']"
    assert_select "input[name='account_statement[closing_balance]'][value='1500']"
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

  test "rejected statement stays in the inbox where it can be deleted" do
    statement = AccountStatement.create_from_upload!(
      family: @account.family,
      account: nil,
      file: uploaded_file(filename: "rejected_statement.csv", content_type: "text/csv", content: "date,amount\n2024-01-01,1\n")
    )
    statement.update!(suggested_account: @account, match_confidence: 0.9)

    get account_statements_url
    assert_select "tr##{dom_id(statement)}", count: 1

    patch reject_account_statement_url(statement)
    follow_redirect!

    assert_select "tr##{dom_id(statement)}", count: 1 do
      assert_select "a[href=?]", account_statement_path(statement)
      assert_select "span", text: I18n.t("account_statements.status.rejected")
    end
  end

  test "an unknown currency redraws the form with its error" do
    statement = AccountStatement.create_from_upload!(
      family: @account.family,
      account: @account,
      file: uploaded_file(filename: "statement.csv", content_type: "text/csv", content: "date,amount\n2024-01-01,1\n")
    )

    statement.update_column(:currency, "EUR")

    patch account_statement_url(statement), params: { account_statement: { currency: "ZZZ", closing_balance: "12.50" } }

    assert_response :unprocessable_entity
    assert_select "select[name='account_statement[currency]'] option[selected][value='EUR']"
    assert_select "[data-controller~='money-field'][data-money-field-separator-currency-value='EUR'] input[name='account_statement[closing_balance]']"
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

  test "destroy keeps a statement that an import still carries" do
    statement = AccountStatement.create_from_upload!(
      family: @account.family,
      account: @account,
      file: uploaded_file(filename: "statement.csv", content_type: "text/csv", content: "date,amount\n2024-01-01,1\n")
    )
    import = TransactionImport.create!(family: @account.family, account: @account, account_statement: statement)

    assert_no_difference "AccountStatement.count" do
      delete account_statement_url(statement)
    end

    assert_redirected_to account_url(@account, tab: "statements")
    assert_equal I18n.t("account_statements.destroy.failure"), flash[:alert]
    assert_equal statement.id, import.reload.account_statement_id
  end

  test "destroy reports failure when the database refuses the delete" do
    statement = AccountStatement.create_from_upload!(
      family: @account.family,
      account: @account,
      file: uploaded_file(filename: "statement.csv", content_type: "text/csv", content: "date,amount\n2024-01-01,1\n")
    )
    # An import committed between the model's check and the DELETE.
    AccountStatement.any_instance.stubs(:destroy).raises(ActiveRecord::InvalidForeignKey)

    assert_no_difference "AccountStatement.count" do
      delete account_statement_url(statement)
    end

    assert_redirected_to account_url(@account, tab: "statements")
    assert_equal I18n.t("account_statements.destroy.failure"), flash[:alert]
  end

  test "statement vault lists linked statements by period and the inbox by upload" do
    february = statement_for(account: @account, month: Date.new(2024, 2, 1), name: "february")
    april = statement_for(account: @account, month: Date.new(2024, 4, 1), name: "april")
    march = statement_for(account: @account, month: Date.new(2024, 3, 1), name: "march")
    older_upload = statement_for(account: nil, month: Date.new(2024, 4, 1), name: "older_upload")
    newer_upload = statement_for(account: nil, month: Date.new(2024, 2, 1), name: "newer_upload")
    older_upload.update_columns(created_at: 2.days.ago)
    newer_upload.update_columns(created_at: 1.day.ago)

    get account_statements_url

    assert_response :success
    assert_equal [ newer_upload, older_upload, april, march, february ].map { |statement| dom_id(statement) },
                 css_select("tr[id^='account_statement_']").map { |row| row["id"] }
  end

  private

    def statement_for(account:, month:, name:)
      statement = AccountStatement.create_from_upload!(
        family: @account.family,
        account: account,
        file: uploaded_file(filename: "#{name}.csv", content_type: "text/csv", content: "date,amount\n#{month},1\n#{name}\n")
      )
      statement.update!(period_start_on: month, period_end_on: month.end_of_month)
      statement
    end
end
