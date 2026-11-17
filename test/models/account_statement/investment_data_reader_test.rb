require "test_helper"

class AccountStatement::InvestmentDataReaderTest < ActiveSupport::TestCase
  FakeProvider = Struct.new(:data) do
    def extract_document_data(**)
      Provider::Response.new(success?: true, data: data, error: nil)
    end
  end

  setup do
    @account = accounts(:investment)
    @statement = AccountStatement.create_from_upload!(
      family: families(:dylan_family),
      account: @account,
      file: uploaded_file(filename: "statement.pdf", content_type: "application/pdf", content: "%PDF-1.4\n%fake\n")
    )
  end

  test "stores contributions read from a statement and replaces them on a second read" do
    provider = FakeProvider.new({
      "contributions" => [
        { "date" => "2025-12-31", "amount" => 20000, "kind" => "contribution", "description" => "Employee contributions" },
        { "date" => "2025-12-31", "amount" => 1500.00, "kind" => "employer_contribution", "description" => nil },
        { "date" => "not a date", "amount" => 1, "kind" => "contribution" }
      ]
    })
    AccountStatement::InvestmentDataReader.stubs(:provider).returns(provider)

    reader = AccountStatement::InvestmentDataReader.new(@statement, kind: "contributions")
    assert_equal 2, reader.read!
    assert_equal 2, reader.read!

    records = @account.account_contributions.where(account_statement: @statement)
    assert_equal 2, records.count
    assert records.all?(&:from_statement?)
  end

  test "stores grants and vests read from a document" do
    provider = FakeProvider.new({
      "grants" => [
        { "grant_identifier" => "RS9", "ticker" => "acme", "grant_type" => "rsu", "grant_date" => "2025-03-01", "total_units" => 240,
          "vests" => [ { "vest_date" => "2026-03-15", "units" => 60, "units_withheld" => 25 }, { "vest_date" => "2026-06-15", "units" => 60 } ] }
      ]
    })
    AccountStatement::InvestmentDataReader.stubs(:provider).returns(provider)

    AccountStatement::InvestmentDataReader.new(@statement, kind: "equity_grants").read!

    grant = @account.equity_grants.find_by!(grant_identifier: "RS9")
    assert_equal "ACME", grant.ticker
    assert_equal 2, grant.vests.count
    assert_equal 25, grant.vests.first.units_withheld
  end

  test "explains when no AI provider can read documents" do
    AccountStatement::InvestmentDataReader.stubs(:provider).returns(nil)

    error = assert_raises(AccountStatement::InvestmentDataReader::Error) do
      AccountStatement::InvestmentDataReader.new(@statement, kind: "contributions").read!
    end
    assert_match "AI provider", error.message
  end
end
