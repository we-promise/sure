require "test_helper"

class Import::SecurityMappingTest < ActiveSupport::TestCase
  setup do
    @import = imports(:trade)
    @import.update!(date_format: "%Y-%m-%d")
  end

  test "mappables_by_key auto-matches a seeded security by ticker and leaves unknown labels unmatched" do
    aapl = securities(:aapl)

    create_row(ticker: "AAPL")
    create_row(ticker: "VANGUARD TOTAL BOND ETF MARKET")

    result = Import::SecurityMapping.mappables_by_key(@import)

    assert_equal aapl, result["AAPL"]
    assert_nil result["VANGUARD TOTAL BOND ETF MARKET"]
  end

  test "mappables_by_key keys off distinct, stripped tickers" do
    create_row(ticker: " AAPL ")
    create_row(ticker: "AAPL")

    result = Import::SecurityMapping.mappables_by_key(@import)

    assert_equal [ "AAPL" ], result.keys
  end

  test "values_count counts rows by ticker" do
    create_row(ticker: "AAPL")
    create_row(ticker: "AAPL")
    create_row(ticker: "MSFT")

    mapping = @import.mappings.create!(key: "AAPL", type: "Import::SecurityMapping")

    assert_equal 2, mapping.values_count
  end

  test "create_mappable! resolves a combobox value to a security" do
    msft = securities(:msft)
    resolver = mock
    resolver.stubs(:resolve).returns(msft)

    Security::Resolver.expects(:new)
                      .with("MSFT", exchange_operating_mic: "XNAS", price_provider: nil)
                      .returns(resolver)

    mapping = @import.mappings.create!(
      key: "MICROSOFT CORP",
      type: "Import::SecurityMapping",
      value: "MSFT|XNAS|"
    )

    mapping.create_mappable!

    assert_equal msft, mapping.reload.mappable
  end

  test "create_mappable! is a no-op when value is blank" do
    mapping = @import.mappings.create!(key: "AAPL", type: "Import::SecurityMapping")

    Security::Resolver.expects(:new).never

    mapping.create_mappable!

    assert_nil mapping.reload.mappable
  end

  private
    def create_row(ticker:)
      @import.rows.create!(
        source_row_number: @import.rows.count + 1,
        ticker: ticker,
        date: "2024-01-01",
        qty: "1",
        price: "100",
        currency: "USD"
      )
    end
end
