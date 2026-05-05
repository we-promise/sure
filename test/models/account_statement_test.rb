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

  test "coverage marks covered duplicate ambiguous and mismatched months" do
    covered_month = 4.months.ago.to_date.beginning_of_month
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
