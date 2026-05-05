require "test_helper"

class AccountStatementTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @account = accounts(:depository)
  end

  test "creates linked statement from upload without importing transactions" do
    assert_no_difference [ "Import.count", "Entry.count", "Transaction.count" ] do
      statement = AccountStatement.create_from_upload!(
        family: @family,
        account: @account,
        file: uploaded_file(
          filename: "Chase_2024-01_account_6789.csv",
          content_type: "text/csv",
          content: "date,description,amount\n2024-01-01,Coffee,-5.00\n2024-01-31,Deposit,100.00\n"
        )
      )

      assert statement.linked?
      assert_equal @account, statement.account
      assert_equal Date.new(2024, 1, 1), statement.period_start_on
      assert_equal Date.new(2024, 1, 31), statement.period_end_on
      assert_equal "USD", statement.currency
      assert_equal Digest::SHA256.hexdigest("date,description,amount\n2024-01-01,Coffee,-5.00\n2024-01-31,Deposit,100.00\n"), statement.content_sha256
      assert statement.original_file.attached?
    end
  end

  test "suggests obvious account match without linking inbox upload" do
    @account.update!(institution_name: "Chase Bank", notes: "Statement account ending 6789")

    statement = AccountStatement.create_from_upload!(
      family: @family,
      account: nil,
      file: uploaded_file(
        filename: "Chase_Bank_2024-01_account_6789.pdf",
        content_type: "application/pdf",
        content: "%PDF-1.4 statement"
      )
    )

    assert statement.unmatched?
    assert_nil statement.account
    assert_equal @account, statement.suggested_account
    assert_operator statement.match_confidence, :>=, 0.7
  end

  test "rejects duplicate checksum within family" do
    file_content = "date,description,amount\n2024-01-01,Coffee,-5.00\n"
    AccountStatement.create_from_upload!(
      family: @family,
      account: @account,
      file: uploaded_file(filename: "statement.csv", content_type: "text/csv", content: file_content)
    )

    error = assert_raises(AccountStatement::DuplicateUploadError) do
      AccountStatement.create_from_upload!(
        family: @family,
        account: @account,
        file: uploaded_file(filename: "statement-copy.csv", content_type: "text/csv", content: file_content)
      )
    end

    assert_equal "statement.csv", error.statement.filename
  end

  test "reports duplicate upload after database uniqueness race" do
    file_content = "date,description,amount\n2024-01-01,Coffee,-5.00\n"
    existing = AccountStatement.create_from_upload!(
      family: @family,
      account: @account,
      file: uploaded_file(filename: "statement.csv", content_type: "text/csv", content: file_content)
    )
    prepared_upload = AccountStatement.prepare_upload!(
      uploaded_file(filename: "statement-copy.csv", content_type: "text/csv", content: file_content)
    )

    AccountStatement.stubs(:duplicate_for).returns(nil, existing)
    AccountStatement.any_instance.stubs(:save!).raises(ActiveRecord::RecordNotUnique.new("duplicate"))

    error = assert_raises(AccountStatement::DuplicateUploadError) do
      AccountStatement.create_from_prepared_upload!(
        family: @family,
        account: @account,
        prepared_upload: prepared_upload
      )
    end

    assert_equal existing, error.statement
  end

  test "allows same checksum in different families" do
    file_content = "date,description,amount\n2024-01-01,Coffee,-5.00\n"

    assert_difference "AccountStatement.count", 2 do
      AccountStatement.create_from_upload!(
        family: @family,
        account: @account,
        file: uploaded_file(filename: "statement.csv", content_type: "text/csv", content: file_content)
      )

      AccountStatement.create_from_upload!(
        family: families(:empty),
        account: nil,
        file: uploaded_file(filename: "statement.csv", content_type: "text/csv", content: file_content)
      )
    end
  end

  test "validates linked account family" do
    statement = AccountStatement.create_from_upload!(
      family: @family,
      account: @account,
      file: uploaded_file(filename: "statement.csv", content_type: "text/csv", content: "date,amount\n2024-01-01,1\n")
    )

    statement.account = Account.create!(
      family: families(:empty),
      owner: users(:empty),
      name: "Other family account",
      balance: 0,
      currency: "USD",
      accountable: Depository.new
    )

    assert_not statement.valid?
    assert_includes statement.errors[:account], "is invalid"
  end

  test "validates statement currency codes" do
    statement = AccountStatement.create_from_upload!(
      family: @family,
      account: @account,
      file: uploaded_file(filename: "statement.csv", content_type: "text/csv", content: "date,amount\n2024-01-01,1\n")
    )

    statement.currency = "NOPE"

    assert_not statement.valid?
    assert_includes statement.errors[:currency], "is invalid"
  end

  test "rejects unsupported file extension even when mime type is broadly allowed" do
    assert_raises(AccountStatement::InvalidUploadError) do
      AccountStatement.create_from_upload!(
        family: @family,
        account: @account,
        file: uploaded_file(filename: "statement.txt", content_type: "text/plain", content: "date,amount\n2024-01-01,1\n")
      )
    end

    assert_raises(AccountStatement::InvalidUploadError) do
      AccountStatement.create_from_upload!(
        family: @family,
        account: @account,
        file: uploaded_file(filename: "statement.xls", content_type: "application/vnd.ms-excel", content: "date,amount\n2024-01-01,1\n")
      )
    end
  end

  test "stores sanitized csv parser output without raw rows" do
    statement = AccountStatement.create_from_upload!(
      family: @family,
      account: @account,
      file: uploaded_file(
        filename: "Checking_2024-01.csv",
        content_type: "text/csv",
        content: "posted_at,description,amount\n2024-01-01,Coffee Shop,-5.00\n2024-01-31,Payroll,100.00\n"
      )
    )

    assert_equal Date.new(2024, 1, 1), statement.period_start_on
    assert_equal Date.new(2024, 1, 31), statement.period_end_on
    assert_equal "posted_at", statement.sanitized_parser_output.dig("csv", "date_header")
    assert_equal 2, statement.sanitized_parser_output.dig("csv", "rows_sampled")
    assert_not_includes statement.sanitized_parser_output.to_json, "Coffee Shop"
    assert_not_includes statement.sanitized_parser_output.to_json, "Payroll"
  end

  test "samples csv metadata without parsing raw rows into sanitized output" do
    rows = 300.times.map { |index| "2024-01-#{(index % 28) + 1},Row #{index}" }.join("\n")
    statement = AccountStatement.create_from_upload!(
      family: @family,
      account: @account,
      file: uploaded_file(
        filename: "Checking_2024-01.csv",
        content_type: "text/csv",
        content: "posted_at,description\n#{rows}\n"
      )
    )

    assert_equal 250, statement.sanitized_parser_output.dig("csv", "rows_sampled")
    assert_not_includes statement.sanitized_parser_output.to_json, "Row 299"
  end

  test "preserves sanitized pdf metadata output" do
    statement = AccountStatement.create_from_upload!(
      family: @family,
      account: nil,
      file: uploaded_file(
        filename: "Statement.pdf",
        content_type: "application/pdf",
        content: "%PDF-1.4 statement"
      )
    )

    assert_equal "filename_only", statement.sanitized_parser_output["pdf_detection"]
    assert_empty statement.sanitized_parser_output["metadata_sources"]
    assert_nil statement.institution_name_hint
    assert_nil statement.account_name_hint
    assert_equal 0.1.to_d, statement.parser_confidence
  end

  test "handles malformed csv metadata detection without raw parser output" do
    statement = AccountStatement.create_from_upload!(
      family: @family,
      account: nil,
      file: uploaded_file(
        filename: "Unknown 2024-02.csv",
        content_type: "text/csv",
        content: "date,description\n\"unterminated"
      )
    )

    assert_equal Date.new(2024, 2, 1), statement.period_start_on
    assert_equal Date.new(2024, 2, 29), statement.period_end_on
    assert_nil statement.sanitized_parser_output["csv"]
    assert_not_includes statement.sanitized_parser_output.to_json, "unterminated"
  end

  test "reports reconciliation unavailable when balances are missing" do
    statement = AccountStatement.create_from_upload!(
      family: @family,
      account: @account,
      file: uploaded_file(filename: "statement.csv", content_type: "text/csv", content: "date,amount\n2024-01-01,1\n")
    )
    statement.update!(
      period_start_on: Date.new(2024, 1, 1),
      period_end_on: Date.new(2024, 1, 31),
      closing_balance: 100
    )

    assert_empty statement.reconciliation_checks
    assert_equal "unavailable", statement.reconciliation_status
  end

  test "database constraints reject invalid persisted status values" do
    attrs = {
      family_id: @family.id,
      filename: "statement.csv",
      content_type: "text/csv",
      byte_size: 1,
      checksum: SecureRandom.base64(16),
      source: "provider_sync",
      upload_status: "stored",
      review_status: "unmatched"
    }

    assert_raises(ActiveRecord::StatementInvalid) do
      AccountStatement.transaction(requires_new: true) do
        AccountStatement.insert_all!([ attrs ], record_timestamps: true)
      end
    end
  end

  test "moves linked statements to inbox when account is deleted" do
    account = Account.create!(
      family: @family,
      owner: users(:family_admin),
      name: "Temporary Checking",
      balance: 0,
      currency: "USD",
      accountable: Depository.new
    )
    statement = AccountStatement.create_from_upload!(
      family: @family,
      account: account,
      file: uploaded_file(filename: "statement.csv", content_type: "text/csv", content: "date,amount\n2024-01-01,1\n")
    )

    account.destroy!

    statement.reload
    assert_nil statement.account
    assert statement.unmatched?
    assert_includes @family.account_statements.unmatched, statement
  end

  test "normalizes account last four hint when matching accounts" do
    @account.update!(institution_name: "Acme Bank", notes: "Masked statement suffix abcd")

    statement = AccountStatement.new(
      family: @family,
      institution_name_hint: "Acme",
      account_last4_hint: "ABCD",
      currency: @account.currency
    )

    match = AccountStatement::AccountMatcher.new(statement).best_match

    assert_equal @account, match.account
    assert_operator match.confidence, :>=, 0.75.to_d
  end

  test "coverage marks covered duplicate ambiguous and mismatched months" do
    covered_month = 5.months.ago.to_date.beginning_of_month
    missing_month = 4.months.ago.to_date.beginning_of_month
    duplicate_month = 3.months.ago.to_date.beginning_of_month
    ambiguous_month = 2.months.ago.to_date.beginning_of_month
    mismatched_month = 1.month.ago.to_date.beginning_of_month

    create_statement(account: @account, month: covered_month, content: "covered")
    create_statement(account: @account, month: duplicate_month, content: "duplicate-a")
    create_statement(account: @account, month: duplicate_month, content: "duplicate-b")
    create_statement(account: nil, suggested_account: @account, month: ambiguous_month, content: "ambiguous")
    create_statement(account: @account, month: mismatched_month, content: "mismatched", closing_balance: 120)

    @account.balances.create!(
      date: mismatched_month.end_of_month,
      balance: 100,
      currency: "USD",
      start_cash_balance: 100,
      cash_inflows: 0,
      cash_outflows: 0
    )

    coverage = AccountStatement::Coverage.new(
      @account,
      start_month: covered_month,
      end_month: mismatched_month
    )

    statuses = coverage.months.index_by(&:date).transform_values(&:status)
    assert_equal "covered", statuses[covered_month]
    assert_equal "missing", statuses[missing_month]
    assert_equal "duplicate", statuses[duplicate_month]
    assert_equal "ambiguous", statuses[ambiguous_month]
    assert_equal "mismatched", statuses[mismatched_month]
  end

  private

    def create_statement(account:, month:, content:, suggested_account: nil, closing_balance: nil)
      statement = AccountStatement.create_from_upload!(
        family: @family,
        account: account,
        file: uploaded_file(
          filename: "statement_#{content}_#{month.strftime('%Y-%m')}.csv",
          content_type: "text/csv",
          content: "date,amount\n#{month},1\n#{month.end_of_month},2\n#{content}\n"
        )
      )
      statement.update!(
        suggested_account: suggested_account,
        period_start_on: month,
        period_end_on: month.end_of_month,
        closing_balance: closing_balance
      )
      statement
    end

    def uploaded_file(filename:, content_type:, content:)
      tempfile = Tempfile.new([ File.basename(filename, ".*"), File.extname(filename) ])
      tempfile.binmode
      tempfile.write(content)
      tempfile.rewind

      ActionDispatch::Http::UploadedFile.new(
        tempfile: tempfile,
        filename: filename,
        type: content_type
      )
    end
end
