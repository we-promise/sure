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

  test "inbox holds every accountless statement, including rejected suggestions" do
    linked_statement = AccountStatement.create_from_upload!(
      family: @family,
      account: @account,
      file: uploaded_file(filename: "linked.csv", content_type: "text/csv", content: "date,amount\n2024-01-01,1\n")
    )
    unmatched_statement = AccountStatement.create_from_upload!(
      family: @family,
      account: nil,
      file: uploaded_file(filename: "unmatched.csv", content_type: "text/csv", content: "date,amount\n2024-01-02,2\n")
    )
    rejected_statement = AccountStatement.create_from_upload!(
      family: @family,
      account: nil,
      file: uploaded_file(filename: "rejected.csv", content_type: "text/csv", content: "date,amount\n2024-01-03,3\n")
    )
    accountless_linked_statement = AccountStatement.create_from_upload!(
      family: @family,
      account: nil,
      file: uploaded_file(filename: "accountless_linked.csv", content_type: "text/csv", content: "date,amount\n2024-01-04,4\n")
    )
    accountless_linked_statement.update_columns(review_status: "linked")
    rejected_with_account_statement = AccountStatement.create_from_upload!(
      family: @family,
      account: @account,
      file: uploaded_file(filename: "rejected_with_account.csv", content_type: "text/csv", content: "date,amount\n2024-01-05,5\n")
    )
    rejected_with_account_statement.update_columns(review_status: "rejected")

    assert_includes @family.account_statements.inbox, rejected_statement
    rejected_statement.reject_match!

    assert rejected_statement.reload.rejected?
    assert_not_includes @family.account_statements.unmatched, rejected_statement
    assert_includes @family.account_statements.inbox, rejected_statement
    assert_includes @family.account_statements.inbox, unmatched_statement
    assert_not_includes @family.account_statements.inbox, linked_statement
    assert_not_includes @family.account_statements.inbox, accountless_linked_statement
    assert_not_includes @family.account_statements.inbox, rejected_with_account_statement
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

  test "stores another bank's pdf statement and reads its period from the text" do
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
    # An M-PESA statement: "Statement Period: 01st 1 2025 - 01st 7 2025" wins
    # over the filename date, and it has no opening or closing balance.
    assert_equal "text", statement.sanitized_parser_output["pdf_detection"]
    assert_equal Date.new(2025, 1, 1), statement.period_start_on
    assert_equal Date.new(2025, 7, 1), statement.period_end_on
    assert_nil statement.opening_balance
    assert_nil statement.closing_balance
    assert_equal false, statement.sanitized_parser_output.dig("pdf", "balances_detected")
    assert statement.original_file.blob.download.start_with?("%PDF-")
  end

  test "reads period and balances from a Trade Republic statement pdf over a filename date" do
    eur_account = @family.accounts.create!(
      name: "Trade Republic Cash",
      balance: 0,
      currency: "EUR",
      accountable: Depository.new
    )
    fixture_path = file_fixture("account_statements/trade_republic_it_2026_04.pdf")

    statement = AccountStatement.create_from_upload!(
      family: @family,
      account: eur_account,
      file: Rack::Test::UploadedFile.new(
        fixture_path,
        "application/pdf",
        true,
        original_filename: "Trade Republic 2026-03.pdf"
      )
    )

    assert_equal Date.new(2026, 4, 1), statement.period_start_on
    assert_equal Date.new(2026, 4, 30), statement.period_end_on
    assert_equal BigDecimal("1101.14"), statement.opening_balance
    assert_equal BigDecimal("11948.59"), statement.closing_balance
    assert_equal "1234", statement.account_last4_hint
    assert_equal "Trade Republic", statement.institution_name_hint
    assert_equal "text", statement.sanitized_parser_output["pdf_detection"]
    assert_equal "summary_table", statement.sanitized_parser_output.dig("pdf", "balances_source")
    assert_equal [ "pdf_text", "filename" ], statement.sanitized_parser_output["metadata_sources"]
    assert_equal 0.85.to_d, statement.parser_confidence
    assert_not_includes statement.sanitized_parser_output.to_json, "MARIO ROSSI"
  end

  test "reads a Trade Republic statement saved under its default filename" do
    eur_account = @family.accounts.create!(
      name: "Trade Republic Cash",
      balance: 0,
      currency: "EUR",
      accountable: Depository.new
    )

    statement = AccountStatement.create_from_upload!(
      family: @family,
      account: eur_account,
      file: Rack::Test::UploadedFile.new(
        file_fixture("account_statements/trade_republic_it_2026_04.pdf"),
        "application/pdf",
        true,
        original_filename: "Account statement.pdf"
      )
    )

    assert_equal Date.new(2026, 4, 1), statement.period_start_on
    assert_equal Date.new(2026, 4, 30), statement.period_end_on
    assert_equal BigDecimal("11948.59"), statement.closing_balance
    assert_nil statement.institution_name_hint
    assert_nil statement.account_name_hint
    assert_equal [ "pdf_text" ], statement.sanitized_parser_output["metadata_sources"]
  end

  test "skips Trade Republic balances when the statement currency differs" do
    statement = AccountStatement.create_from_upload!(
      family: @family,
      account: nil,
      file: Rack::Test::UploadedFile.new(
        file_fixture("account_statements/trade_republic_it_2026_04.pdf"),
        "application/pdf",
        true,
        original_filename: "statement.pdf"
      )
    )

    assert_equal "USD", statement.currency
    assert_equal Date.new(2026, 4, 1), statement.period_start_on
    assert_equal Date.new(2026, 4, 30), statement.period_end_on
    assert_nil statement.opening_balance
    assert_nil statement.closing_balance
    assert_equal false, statement.sanitized_parser_output.dig("pdf", "balances_detected")
    assert_nil statement.sanitized_parser_output.dig("pdf", "balances_source")
  end

  CARD_STATEMENT_TEXT = <<~TEXT
    Statement period 12 Apr 2024 - 15 May 2024
    Opening balance $1,066.47
    Closing balance $435.88 CR
  TEXT

  # Adds up only as a liability: 1,066.47 + 0.00 - 1,502.35 = -435.88.
  CARD_SUMMARY_TEXT = <<~TEXT
    Statement period 12 Apr 2024 - 15 May 2024
    Opening balance    Debits     Credits      Closing balance
    $1,066.47          $0.00      $1,502.35    $435.88 CR
  TEXT

  test "stores a CR closing balance on a credit card as in credit" do
    statement = upload_card_statement(account: accounts(:credit_card))

    assert_equal BigDecimal("1066.47"), statement.opening_balance
    assert_equal BigDecimal("-435.88"), statement.closing_balance
    assert_equal "labels", statement.sanitized_parser_output.dig("pdf", "balances_source")
    assert_equal({ "amount" => "435.88", "side" => "credit", "currency" => "$" },
                 statement.sanitized_parser_output.dig("pdf", "balance_readings", "labels", "closing_balance"))
  end

  test "stores a DR closing balance on a depository account as overdrawn" do
    statement = upload_card_statement(account: @account, text: CARD_STATEMENT_TEXT.sub(" CR", " DR"))

    assert_equal BigDecimal("-435.88"), statement.closing_balance
  end

  test "signs an inbox upload's CR balance when it is linked to a credit card" do
    statement = upload_card_statement(account: nil)
    assert_equal BigDecimal("435.88"), statement.closing_balance

    statement.link_to_account!(accounts(:credit_card))

    assert_equal BigDecimal("-435.88"), statement.reload.closing_balance
    assert_equal BigDecimal("1066.47"), statement.opening_balance
  end

  test "signs a CR balance when the account is set through an edit" do
    statement = upload_card_statement(account: nil)

    statement.update!(account: accounts(:credit_card))

    assert_equal BigDecimal("-435.88"), statement.reload.closing_balance
  end

  test "re-signs a CR balance when the statement moves to a depository account" do
    statement = upload_card_statement(account: accounts(:credit_card))

    statement.unlink!
    statement.link_to_account!(@account)

    assert_equal BigDecimal("435.88"), statement.reload.closing_balance
  end

  test "unlinking returns a CR balance to its unsigned inbox value" do
    statement = upload_card_statement(account: accounts(:credit_card))

    statement.unlink!

    assert_equal BigDecimal("435.88"), statement.reload.closing_balance
  end

  test "keeps a balance edited by hand before linking" do
    statement = upload_card_statement(account: nil)
    statement.update!(closing_balance: 400)

    statement.link_to_account!(accounts(:credit_card))

    assert_equal BigDecimal("400"), statement.reload.closing_balance
    assert_equal BigDecimal("1066.47"), statement.opening_balance
  end

  test "keeps a balance typed in the same save that sets the account" do
    statement = upload_card_statement(account: nil)

    statement.update!(account: @account, closing_balance: -435.88)

    assert_equal BigDecimal("-435.88"), statement.reload.closing_balance
  end

  test "keeps a deliberately signed balance across relinking" do
    statement = upload_card_statement(account: accounts(:credit_card))
    statement.update!(closing_balance: 435.88)

    statement.unlink!
    statement.link_to_account!(@account)
    statement.link_to_account!(accounts(:credit_card))

    assert_equal BigDecimal("435.88"), statement.reload.closing_balance
  end

  test "keeps a CR summary table on a credit card upload" do
    statement = upload_card_statement(account: accounts(:credit_card), text: CARD_SUMMARY_TEXT)

    assert_equal BigDecimal("-435.88"), statement.closing_balance
    assert_equal "summary_table", statement.sanitized_parser_output.dig("pdf", "balances_source")
  end

  test "drops a CR summary table uploaded to a depository account" do
    statement = upload_card_statement(account: @account, text: CARD_SUMMARY_TEXT)

    assert_nil statement.opening_balance
    assert_nil statement.closing_balance
    assert_nil statement.sanitized_parser_output.dig("pdf", "balances_source")
    assert_equal false, statement.sanitized_parser_output.dig("pdf", "balances_detected")
  end

  test "drops an inbox summary table when it is linked to an account it does not add up for" do
    statement = upload_card_statement(account: nil, text: CARD_SUMMARY_TEXT)
    assert_equal BigDecimal("435.88"), statement.closing_balance

    statement.link_to_account!(@account)

    assert_nil statement.reload.opening_balance
    assert_nil statement.closing_balance
    assert_nil statement.sanitized_parser_output.dig("pdf", "balances_source")
    assert_equal false, statement.sanitized_parser_output.dig("pdf", "balances_detected")
  end

  test "drops a card upload's summary table when it moves to a depository account" do
    statement = upload_card_statement(account: accounts(:credit_card), text: CARD_SUMMARY_TEXT)

    statement.unlink!
    statement.link_to_account!(@account)

    assert_nil statement.reload.opening_balance
    assert_nil statement.closing_balance
  end

  test "restores a dropped summary table when relinked to an account it adds up for" do
    statement = upload_card_statement(account: @account, text: CARD_SUMMARY_TEXT)
    assert_nil statement.closing_balance

    statement.unlink!
    statement.link_to_account!(accounts(:credit_card))

    assert_equal BigDecimal("1066.47"), statement.reload.opening_balance
    assert_equal BigDecimal("-435.88"), statement.closing_balance
    assert_equal "summary_table", statement.sanitized_parser_output.dig("pdf", "balances_source")
    assert_equal true, statement.sanitized_parser_output.dig("pdf", "balances_detected")
  end

  test "keeps an edited balance when the summary table is dropped" do
    statement = upload_card_statement(account: nil, text: CARD_SUMMARY_TEXT)
    statement.update!(closing_balance: 400)

    statement.link_to_account!(@account)

    assert_nil statement.reload.opening_balance
    assert_equal BigDecimal("400"), statement.closing_balance
  end

  test "unlinking keeps an inbox summary table that adds up only as a card's" do
    statement = upload_card_statement(account: nil, text: CARD_SUMMARY_TEXT)
    statement.link_to_account!(accounts(:credit_card))

    statement.unlink!

    assert_equal BigDecimal("1066.47"), statement.reload.opening_balance
    assert_equal BigDecimal("435.88"), statement.closing_balance
  end

  test "reads the balances again in the statement's currency when it changes" do
    @family.update!(currency: "EUR")
    card = @family.accounts.create!(name: "AUD card", balance: 0, currency: "AUD", accountable: CreditCard.new)
    statement = upload_card_statement(account: nil)
    assert_equal "EUR", statement.currency
    assert_nil statement.closing_balance, "a dollar amount was read as euros"

    statement.link_to_account!(card)
    statement.update!(currency: "AUD")

    assert_equal BigDecimal("-435.88"), statement.reload.closing_balance
    assert_equal BigDecimal("1066.47"), statement.opening_balance
  end

  test "a save that fails validation and is retried does not mark derived balances as edited" do
    statement = upload_card_statement(account: nil)
    statement.account = accounts(:credit_card)
    statement.period_end_on = statement.period_start_on - 1
    assert_not statement.save

    statement.period_end_on = statement.period_start_on + 30
    statement.save!
    statement.unlink!

    assert_empty Array(statement.reload.sanitized_parser_output.dig("pdf", "edited_balances"))
    assert_equal BigDecimal("435.88"), statement.closing_balance
  end

  test "balances posted back from a failed save stay derived" do
    @family.update!(currency: "EUR")
    statement = upload_card_statement(account: nil)
    assert_nil statement.closing_balance, "a dollar amount was read as euros"
    statement.currency = "USD"
    statement.period_end_on = statement.period_start_on - 1
    assert_not statement.save
    assert_equal BigDecimal("435.88"), statement.closing_balance

    # The form re-renders the derived values, and the next request posts them
    # back on a fresh record.
    retried = AccountStatement.find(statement.id)
    retried.update!(
      currency: "USD",
      period_end_on: retried.period_start_on + 30,
      opening_balance: statement.opening_balance.to_s,
      closing_balance: statement.closing_balance.to_s
    )
    retried.link_to_account!(accounts(:credit_card))

    assert_equal BigDecimal("-435.88"), retried.reload.closing_balance
    assert_empty Array(retried.sanitized_parser_output.dig("pdf", "edited_balances"))
  end

  test "a retry after an invalid currency re-derives the balances" do
    statement = upload_card_statement(account: nil)
    assert_equal "USD", statement.currency
    statement.currency = "NOPE"
    assert_not statement.save

    statement.currency = "USD"
    statement.save!

    assert_equal BigDecimal("435.88"), statement.reload.closing_balance
    assert_equal BigDecimal("1066.47"), statement.opening_balance
  end

  test "leaves statements without balance readings alone when linked" do
    statement = upload_card_statement(account: nil, text: "nothing to read")
    statement.update!(closing_balance: 250)

    statement.link_to_account!(accounts(:credit_card))

    assert_equal BigDecimal("250"), statement.reload.closing_balance
  end

  test "does not read a bare MM-YYYY token in the filename as the period" do
    statement = AccountStatement.create_from_upload!(
      family: @family,
      account: nil,
      file: uploaded_file(
        filename: "Invoice_04-2029.pdf",
        content_type: "application/pdf",
        content: "%PDF-1.4 statement"
      )
    )

    assert_nil statement.period_start_on
    assert_nil statement.period_end_on
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
    account = Account.create!(
      family: @family,
      owner: users(:family_admin),
      name: "Coverage Checking",
      balance: 0,
      currency: "USD",
      accountable: Depository.new
    )

    covered_month = 5.months.ago.to_date.beginning_of_month
    missing_month = 4.months.ago.to_date.beginning_of_month
    duplicate_month = 3.months.ago.to_date.beginning_of_month
    ambiguous_month = 2.months.ago.to_date.beginning_of_month
    mismatched_month = 1.month.ago.to_date.beginning_of_month

    create_statement(account: account, month: covered_month, content: "covered")
    create_statement(account: account, month: duplicate_month, content: "duplicate-a")
    create_statement(account: account, month: duplicate_month, content: "duplicate-b")
    create_statement(account: nil, suggested_account: account, month: ambiguous_month, content: "ambiguous")
    create_statement(account: account, month: mismatched_month, content: "mismatched", closing_balance: 120)

    account.balances.create!(
      date: mismatched_month.end_of_month,
      balance: 100,
      currency: "USD",
      start_cash_balance: 100,
      cash_inflows: 0,
      cash_outflows: 0
    )

    coverage = AccountStatement::Coverage.new(
      account,
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

  test "coverage does not mark adjacent statements as duplicate when they only share a calendar month" do
    account = Account.create!(
      family: @family,
      owner: users(:family_admin),
      name: "Adjacent Statement Checking",
      balance: 0,
      currency: "USD",
      accountable: Depository.new
    )

    march = Date.new(2026, 3, 1)

    create_statement_with_period(
      account: account,
      period_start_on: Date.new(2026, 1, 8),
      period_end_on: Date.new(2026, 3, 6),
      content: "adjacent-a"
    )

    create_statement_with_period(
      account: account,
      period_start_on: Date.new(2026, 3, 7),
      period_end_on: Date.new(2026, 4, 7),
      content: "adjacent-b"
    )

    coverage = AccountStatement::Coverage.new(
      account,
      start_month: march,
      end_month: march
    )

    assert_equal "covered", coverage.months.first.status
  end

  test "by_period lists the newest period first and statements without a period last" do
    march = create_statement_with_period(account: @account, period_start_on: Date.new(2024, 3, 1), period_end_on: Date.new(2024, 3, 31), content: "march")
    unread = create_statement_with_period(account: @account, period_start_on: nil, period_end_on: nil, content: "unread")
    january = create_statement_with_period(account: @account, period_start_on: Date.new(2024, 1, 1), period_end_on: Date.new(2024, 1, 31), content: "january")
    quarter = create_statement_with_period(account: @account, period_start_on: Date.new(2024, 1, 1), period_end_on: Date.new(2024, 3, 31), content: "quarter")
    january_again = create_statement_with_period(account: @account, period_start_on: Date.new(2024, 1, 1), period_end_on: Date.new(2024, 1, 31), content: "january_again")
    january.update_columns(created_at: 2.days.ago)
    january_again.update_columns(created_at: 1.day.ago)

    assert_equal [ march, quarter, january_again, january, unread ], @account.account_statements.by_period.to_a
  end

  test "by_period lists a statement with only one end of its period with the unknown periods, by upload" do
    march = create_statement_with_period(account: @account, period_start_on: Date.new(2024, 3, 1), period_end_on: Date.new(2024, 3, 31), content: "march")
    unread = create_statement_with_period(account: @account, period_start_on: nil, period_end_on: nil, content: "unread")
    end_only = create_statement_with_period(account: @account, period_start_on: nil, period_end_on: Date.new(2024, 4, 30), content: "end_only")
    start_only = create_statement_with_period(account: @account, period_start_on: Date.new(2024, 5, 1), period_end_on: nil, content: "start_only")
    unread.update_columns(created_at: 3.hours.ago)
    end_only.update_columns(created_at: 2.hours.ago)
    start_only.update_columns(created_at: 1.hour.ago)

    assert_equal [ march, start_only, end_only, unread ], @account.account_statements.by_period.to_a
  end

  private

    def upload_card_statement(account:, text: CARD_STATEMENT_TEXT)
      Pdf::TextExtractor.stubs(:pages).returns([ text ])
      AccountStatement.create_from_upload!(
        family: @family,
        account: account,
        file: uploaded_file(filename: "card.pdf", content_type: "application/pdf", content: "%PDF-1.4 card statement")
      )
    end

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

    def create_statement_with_period(account:, period_start_on:, period_end_on:, content:, suggested_account: nil)
      statement = AccountStatement.create_from_upload!(
        family: @family,
        account: account,
        file: uploaded_file(
          filename: "statement_#{content}_#{period_start_on}_#{period_end_on}.csv",
          content_type: "text/csv",
          content: "date,amount\n#{period_start_on},1\n#{period_end_on},2\n#{content}\n"
        )
      )

      statement.update!(
        suggested_account: suggested_account,
        period_start_on: period_start_on,
        period_end_on: period_end_on
      )

      statement
    end
end
