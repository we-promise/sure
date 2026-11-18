require "test_helper"

class AccountStatement::EquityGrantReaderTest < ActiveSupport::TestCase
  FakeProvider = Struct.new(:data) do
    def extract_document_data(**)
      Provider::Response.new(success?: true, data: data, error: nil)
    end
  end

  setup do
    @account = accounts(:investment)
    @account.investment.update!(subtype: "stock_plan")
    @statement = AccountStatement.create_from_upload!(
      family: families(:dylan_family),
      account: @account,
      file: uploaded_file(filename: "grant.pdf", content_type: "application/pdf", content: "%PDF-1.4\n%example\n")
    )
    Ai.stubs(:availability).returns(Ai::Availability.available(:extract_pdf))
  end

  test "stores grants and vests and marks the statement read" do
    use_provider("grants" => [ grant_row(vests: [ { "vest_date" => "2026-03-15", "units" => 60, "units_withheld" => 25 }, { "vest_date" => "2026-06-15", "units" => 60 } ]) ])

    assert_equal 1, reader.read!

    grant = @account.equity_grants.find_by!(grant_identifier: "RS9")
    assert_equal "ACME", grant.ticker
    assert_equal [ 25, nil ], grant.vests.map(&:units_withheld)
    assert @statement.reload.equity_grants_read_at.present?
  end

  test "reading the same statement again replaces its own vests only" do
    other = @account.equity_grants.create!(ticker: "ACME", grant_identifier: "RS9")
    other.vests.create!(vest_date: Date.new(2026, 9, 15), units: 7, source: "manual")
    use_provider("grants" => [ grant_row(vests: [ { "vest_date" => "2026-03-15", "units" => 60 } ]) ])
    reader.read!

    use_provider("grants" => [ grant_row(vests: [ { "vest_date" => "2026-06-15", "units" => 55 } ]) ])
    reader.read!

    assert_equal [ [ Date.new(2026, 6, 15), 55 ], [ Date.new(2026, 9, 15), 7 ] ], other.vests.reload.map { |v| [ v.vest_date, v.units ] }
  end

  test "an answer without a grants list changes nothing" do
    grant = @account.equity_grants.create!(ticker: "ACME", grant_identifier: "RS9")
    grant.vests.create!(vest_date: Date.new(2026, 3, 15), units: 60, source: "statement", account_statement: @statement)
    use_provider({})

    assert_raises(AccountStatement::EquityGrantReader::Error) { reader.read! }
    assert_equal 1, grant.vests.count
    assert_nil @statement.reload.equity_grants_read_at
  end

  test "an invalid extracted value becomes a reader error" do
    use_provider("grants" => [ grant_row(ticker: "T" * 30, vests: []) ])

    assert_raises(AccountStatement::EquityGrantReader::Error) { reader.read! }
  end

  test "refuses when the PDF-extraction route isn't available" do
    Ai.stubs(:availability).returns(Ai::Availability.unavailable(:extract_pdf, :not_configured))

    assert_raises(AccountStatement::EquityGrantReader::Error) { reader.read! }
  end

  test "only reads documents on stock plan accounts" do
    @account.investment.update!(subtype: "brokerage")

    assert_raises(AccountStatement::EquityGrantReader::Error) { reader.read! }
  end

  private
    def reader = AccountStatement::EquityGrantReader.new(@statement, user: users(:family_admin))

    def use_provider(data)
      Provider::Registry.stubs(:preferred_llm_provider).returns(FakeProvider.new(data))
    end

    def grant_row(vests:, ticker: "acme")
      { "grant_identifier" => "RS9", "ticker" => ticker, "grant_type" => "rsu", "grant_date" => "2025-03-01", "total_units" => 240, "vests" => vests }
    end
end
