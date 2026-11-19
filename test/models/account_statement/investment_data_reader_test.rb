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

  test "re-reading replaces only this statement's extracted vests" do
    provider = FakeProvider.new({ "grants" => [
      { "grant_identifier" => "EXAMPLE-1", "ticker" => "ACME", "grant_type" => "rsu", "total_units" => 100,
        "vests" => [ { "vest_date" => "2027-03-01", "units" => 10 } ] }
    ] })
    AccountStatement::InvestmentDataReader.stubs(:provider).returns(provider)
    reader = AccountStatement::InvestmentDataReader.new(@statement, kind: "equity_grants")
    reader.read!
    grant = @account.equity_grants.find_by!(grant_identifier: "EXAMPLE-1")
    manual = grant.vests.create!(vest_date: "2027-06-01", units: 20, source: "manual")
    csv = grant.vests.create!(vest_date: "2027-09-01", units: 30, source: "csv")
    other_statement = AccountStatement.create_from_upload!(family: @account.family, account: @account,
      file: uploaded_file(filename: "other.pdf", content_type: "application/pdf", content: "%PDF-1.4\n%other\n"))
    other = grant.vests.create!(vest_date: "2027-12-01", units: 40, source: "statement", account_statement: other_statement)

    provider.data["grants"].first["vests"] = [
      { "vest_date" => "2027-03-15", "units" => 15 },
      { "vest_date" => "2027-06-01", "units" => 99 }
    ]
    reader.read!
    reader.read!

    assert_equal 4, grant.vests.count
    assert_not grant.vests.exists?(vest_date: "2027-03-01")
    replacement = grant.vests.find_by!(vest_date: "2027-03-15")
    assert_equal @statement, replacement.account_statement
    assert replacement.from_statement?
    assert_equal 15, replacement.units
    assert_equal 20, manual.reload.units
    assert_equal 30, csv.reload.units
    assert_equal 40, other.reload.units
  end

  test "re-reading removes grants no longer extracted without deleting manual grants" do
    provider = FakeProvider.new({ "grants" => [
      { "grant_identifier" => "EXAMPLE-1", "ticker" => "ACME", "grant_type" => "rsu", "total_units" => 100,
        "vests" => [ { "vest_date" => "2027-03-01", "units" => 10 } ] }
    ] })
    AccountStatement::InvestmentDataReader.stubs(:provider).returns(provider)
    reader = AccountStatement::InvestmentDataReader.new(@statement, kind: "equity_grants")
    reader.read!
    manual = @account.equity_grants.create!(ticker: "EXAMPLE", source: "manual")

    provider.data["grants"] = []
    reader.read!

    assert_equal [ manual.id ], @account.equity_grants.pluck(:id)
  end

  test "a failed replacement restores the previous extracted schedule" do
    provider = FakeProvider.new({ "grants" => [
      { "grant_identifier" => "EXAMPLE-1", "ticker" => "ACME", "grant_type" => "rsu", "total_units" => 100,
        "vests" => [ { "vest_date" => "2027-03-01", "units" => 10 } ] }
    ] })
    AccountStatement::InvestmentDataReader.stubs(:provider).returns(provider)
    reader = AccountStatement::InvestmentDataReader.new(@statement, kind: "equity_grants")
    reader.read!
    vest = @account.equity_grants.first.vests.first
    provider.data["grants"].first["total_units"] = -1

    assert_raises(ActiveRecord::RecordInvalid) { reader.read! }
    assert_equal 10, vest.reload.units
  end
end
