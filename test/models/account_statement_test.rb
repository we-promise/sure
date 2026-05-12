require "test_helper"

class AccountStatementTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @account = accounts(:depository)
  end

  OversizedDeclaredUpload = Struct.new(:original_filename, keyword_init: true) do
    def size
      AccountStatement::MAX_FILE_SIZE + 1
    end

    def read(*)
      raise "oversized upload should be rejected before reading"
    end
  end

  class UploadWithoutDeclaredSize
    attr_reader :original_filename, :content_type

    def initialize(filename:, content_type:, content:)
      @original_filename = filename
      @content_type = content_type
      @io = StringIO.new(content)
    end

    def read(length)
      @io.read(length)
    end

    def rewind
      @io.rewind
    end
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
    @account.update!(institution_name: "Chase Bank 6789", notes: "Private note")

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

  test "rejects duplicate sha256 within family" do
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

  test "allows distinct files with same md5 checksum and different sha256" do
    Digest::MD5.stubs(:base64digest).returns("same-md5-checksum")

    assert_difference "AccountStatement.count", 2 do
      AccountStatement.create_from_upload!(
        family: @family,
        account: @account,
        file: uploaded_file(filename: "statement-a.csv", content_type: "text/csv", content: "date,amount\n2024-01-01,1\n")
      )

      AccountStatement.create_from_upload!(
        family: @family,
        account: @account,
        file: uploaded_file(filename: "statement-b.csv", content_type: "text/csv", content: "date,amount\n2024-01-02,2\n")
      )
    end
  end

  test "uses md5 checksum fallback for legacy statements without sha256" do
    Digest::MD5.stubs(:base64digest).returns("legacy-md5-checksum")
    existing = AccountStatement.create_from_upload!(
      family: @family,
      account: @account,
      file: uploaded_file(filename: "legacy.csv", content_type: "text/csv", content: "date,amount\n2024-01-01,1\n")
    )
    existing.update_columns(content_sha256: nil)

    error = assert_raises(AccountStatement::DuplicateUploadError) do
      AccountStatement.create_from_upload!(
        family: @family,
        account: @account,
        file: uploaded_file(filename: "legacy-copy.csv", content_type: "text/csv", content: "date,amount\n2024-01-02,2\n")
      )
    end

    assert_equal existing, error.statement
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

  test "purges staged blob when database uniqueness race is re-raised" do
    prepared_upload = AccountStatement.prepare_upload!(
      uploaded_file(filename: "statement-copy.csv", content_type: "text/csv", content: "date,amount\n2024-01-01,1\n")
    )

    AccountStatement.stubs(:duplicate_for).returns(nil)
    AccountStatement.any_instance.stubs(:save!).raises(ActiveRecord::RecordNotUnique.new("duplicate"))

    assert_no_difference [ "ActiveStorage::Blob.count", "ActiveStorage::Attachment.count" ] do
      assert_raises(ActiveRecord::RecordNotUnique) do
        AccountStatement.create_from_prepared_upload!(
          family: @family,
          account: @account,
          prepared_upload: prepared_upload
        )
      end
    end
  end

  test "purges staged blob when metadata detection fails after attach" do
    AccountStatement::MetadataDetector.any_instance.stubs(:apply).raises(StandardError, "parser failed")

    assert_no_difference [ "ActiveStorage::Blob.count", "ActiveStorage::Attachment.count" ] do
      assert_raises(StandardError) do
        AccountStatement.create_from_upload!(
          family: @family,
          account: @account,
          file: uploaded_file(filename: "statement.csv", content_type: "text/csv", content: "date,amount\n2024-01-01,1\n")
        )
      end
    end
  end

  test "with_account scope keeps account linkage semantics while enum predicate follows review status" do
    linked_statement = AccountStatement.create_from_upload!(
      family: @family,
      account: @account,
      file: uploaded_file(filename: "linked.csv", content_type: "text/csv", content: "date,amount\n2024-01-01,1\n")
    )
    accountless_statement = AccountStatement.create_from_upload!(
      family: @family,
      account: nil,
      file: uploaded_file(filename: "accountless.csv", content_type: "text/csv", content: "date,amount\n2024-01-02,2\n")
    )
    accountless_statement.update_columns(review_status: "linked")

    assert accountless_statement.reload.linked?
    assert_includes @family.account_statements.with_account, linked_statement
    assert_not_includes @family.account_statements.with_account, accountless_statement
    assert_not_includes @family.account_statements.unmatched, accountless_statement
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
        assert_raises(AccountStatement::InvalidUploadError) do
          AccountStatement.create_from_upload!(family: @family, account: @account, file: file)
        end
      end
    end
  end

  test "rejects declared oversized upload before reading content" do
    assert_raises(AccountStatement::InvalidUploadError) do
      AccountStatement.prepare_upload!(OversizedDeclaredUpload.new(original_filename: "oversized.csv"))
    end
  end

  test "streams unknown-size uploads and rejects when content exceeds size limit" do
    file = UploadWithoutDeclaredSize.new(
      filename: "oversized.csv",
      content_type: "text/csv",
      content: "x" * (AccountStatement::MAX_FILE_SIZE + 1)
    )

    assert_raises(AccountStatement::InvalidUploadError) do
      AccountStatement.prepare_upload!(file)
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

  test "detects filename dates separated by underscores" do
    statement = AccountStatement.create_from_upload!(
      family: @family,
      account: @account,
      file: uploaded_file(
        filename: "statement_2024_01_31.csv",
        content_type: "text/csv",
        content: "description,amount\nCoffee,-5.00\n"
      )
    )

    assert_equal Date.new(2024, 1, 1), statement.period_start_on
    assert_equal Date.new(2024, 1, 31), statement.period_end_on
  end

  test "ignores unreasonable filename dates" do
    statement = AccountStatement.create_from_upload!(
      family: @family,
      account: @account,
      file: uploaded_file(
        filename: "statement_1969_01_31.csv",
        content_type: "text/csv",
        content: "description,amount\nCoffee,-5.00\n"
      )
    )

    assert_nil statement.period_start_on
    assert_nil statement.period_end_on
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

  test "bounds csv metadata detection column count" do
    headers = [ "posted_at", *101.times.map { |index| "column_#{index}" } ].join(",")
    values = [ "2024-01-01", *101.times.map { "value" } ].join(",")

    statement = AccountStatement.create_from_upload!(
      family: @family,
      account: @account,
      file: uploaded_file(
        filename: "Checking.csv",
        content_type: "text/csv",
        content: "#{headers}\n#{values}\n"
      )
    )

    assert_nil statement.sanitized_parser_output["csv"]
  end

  test "bounds csv metadata detection sample length" do
    oversized_date = "2024-01-01" + ("x" * AccountStatement::MetadataDetector::MAX_CSV_SAMPLE_BYTES)

    statement = AccountStatement.create_from_upload!(
      family: @family,
      account: @account,
      file: uploaded_file(
        filename: "Checking.csv",
        content_type: "text/csv",
        content: "posted_at,description\n#{oversized_date},oversized\n"
      )
    )

    assert_nil statement.sanitized_parser_output["csv"]
    assert_not_includes statement.sanitized_parser_output.to_json, oversized_date
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

  test "stores an actual pdf document fixture as a statement" do
    fixture_path = file_fixture("imports/sample_bank_statement.pdf")
    statement = AccountStatement.create_from_upload!(
      family: @family,
      account: @account,
      file: Rack::Test::UploadedFile.new(
        fixture_path,
        "application/pdf",
        true,
        original_filename: "sample_bank_statement_2024-01.pdf"
      )
    )

    assert statement.linked?
    assert statement.original_file.attached?
    assert_equal "application/pdf", statement.content_type
    assert_equal fixture_path.size, statement.byte_size
    assert_equal Digest::SHA256.file(fixture_path).hexdigest, statement.content_sha256
    assert_equal "filename_only", statement.sanitized_parser_output["pdf_detection"]
    assert_equal [ "filename" ], statement.sanitized_parser_output["metadata_sources"]
    assert_equal Date.new(2024, 1, 1), statement.period_start_on
    assert_equal Date.new(2024, 1, 31), statement.period_end_on
    assert statement.original_file.blob.download.start_with?("%PDF-")
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

  test "coverage requires account" do
    error = assert_raises(ArgumentError) do
      AccountStatement::Coverage.new(nil)
    end
    assert_match(/account is required/, error.message)
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

  test "database constraints reject empty persisted statement byte sizes" do
    attrs = {
      family_id: @family.id,
      filename: "empty.csv",
      content_type: "text/csv",
      byte_size: 0,
      checksum: SecureRandom.base64(16),
      source: "manual_upload",
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

  test "unlink clears invalid recomputed suggestion" do
    statement = AccountStatement.create_from_upload!(
      family: @family,
      account: @account,
      file: uploaded_file(filename: "statement.csv", content_type: "text/csv", content: "date,amount\n2024-01-01,1\n")
    )
    other_account = Account.create!(
      family: families(:empty),
      owner: users(:empty),
      name: "Other family account",
      balance: 0,
      currency: "USD",
      accountable: Depository.new
    )
    invalid_match = AccountStatement::AccountMatcher::Match.new(account: other_account, confidence: 0.9)
    AccountStatement::AccountMatcher.any_instance.stubs(:best_match).returns(invalid_match)

    statement.unlink!

    statement.reload
    assert_nil statement.account
    assert_nil statement.suggested_account
    assert_nil statement.match_confidence
    assert statement.unmatched?
  end

  test "preserves explicit rejected review status" do
    statement = AccountStatement.create_from_upload!(
      family: @family,
      account: @account,
      file: uploaded_file(filename: "statement.csv", content_type: "text/csv", content: "date,amount\n2024-01-01,1\n")
    )

    statement.reject_match!

    assert statement.rejected?
    assert_equal @account, statement.account
  end

  test "preserves rejected review status across unrelated saves" do
    statement = AccountStatement.create_from_upload!(
      family: @family,
      account: @account,
      file: uploaded_file(filename: "statement.csv", content_type: "text/csv", content: "date,amount\n2024-01-01,1\n")
    )
    statement.reject_match!

    statement.update!(period_start_on: Date.new(2024, 1, 1))

    assert statement.rejected?
    assert_equal @account, statement.account
  end

  test "allows intentional review status changes away from rejected" do
    statement = AccountStatement.create_from_upload!(
      family: @family,
      account: @account,
      file: uploaded_file(filename: "statement.csv", content_type: "text/csv", content: "date,amount\n2024-01-01,1\n")
    )
    statement.reject_match!

    statement.link_to_account!(@account)

    assert statement.linked?
    assert_equal @account, statement.account
  end

  test "normalizes account last four hint when matching accounts" do
    @account.update!(institution_name: "Acme Bank ABCD", notes: "Private note")

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

  test "does not match account last four hints from account notes" do
    @account.update!(institution_name: "Acme Bank", notes: "Masked statement suffix abcd")

    statement = AccountStatement.new(
      family: @family,
      account_last4_hint: "ABCD",
      currency: @account.currency
    )

    assert_nil AccountStatement::AccountMatcher.new(statement).best_match
  end

  test "coverage year selection spans historical account data through last completed month" do
    account = Account.create!(
      family: @family,
      owner: users(:family_admin),
      name: "Historical Checking",
      balance: 0,
      currency: "USD",
      accountable: Depository.new
    )

    travel_to Date.new(2026, 5, 6) do
      create_statement(account: account, month: Date.new(2024, 2, 1), content: "historical")

      current_year_coverage = AccountStatement::Coverage.for_year(account, nil)
      historical_coverage = AccountStatement::Coverage.for_year(account, 2024)

      assert_equal 2026, current_year_coverage.selected_year
      assert_equal [ 2026, 2025, 2024 ], current_year_coverage.available_years

      historical_statuses = historical_coverage.months.index_by(&:date).transform_values(&:status)
      assert_equal "not_expected", historical_statuses[Date.new(2024, 1, 1)]
      assert_equal "covered", historical_statuses[Date.new(2024, 2, 1)]
      assert_equal "missing", historical_statuses[Date.new(2024, 3, 1)]

      current_statuses = current_year_coverage.months.index_by(&:date).transform_values(&:status)
      assert_equal "missing", current_statuses[Date.new(2026, 4, 1)]
      assert_equal "not_expected", current_statuses[Date.new(2026, 5, 1)]
    end
  end

  test "coverage start can come from balances entries and suggested statements" do
    account = Account.create!(
      family: @family,
      owner: users(:family_admin),
      name: "Archive Checking",
      balance: 0,
      currency: "USD",
      accountable: Depository.new
    )

    account.entries.create!(
      name: "Old transaction",
      date: Date.new(2021, 6, 15),
      amount: 10,
      currency: "USD",
      entryable: Transaction.new
    )
    account.balances.create!(date: Date.new(2020, 3, 31), balance: 100, currency: "USD")
    create_statement(account: nil, suggested_account: account, month: Date.new(2019, 7, 1), content: "suggested")

    travel_to Date.new(2026, 5, 6) do
      coverage = AccountStatement::Coverage.for_year(account, 2019)
      statuses = coverage.months.index_by(&:date).transform_values(&:status)

      assert_equal [ 2026, 2025, 2024, 2023, 2022, 2021, 2020, 2019 ], coverage.available_years
      assert_equal "not_expected", statuses[Date.new(2019, 6, 1)]
      assert_equal "ambiguous", statuses[Date.new(2019, 7, 1)]
    end
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
end
