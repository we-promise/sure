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

  test "mappables_by_key matches the row exchange when a MIC is given" do
    aapl_nasdaq = securities(:aapl) # XNAS
    aapl_other = Security.create!(ticker: "AAPL", exchange_operating_mic: "XLON", name: "Apple LSE")

    create_row(ticker: "AAPL", exchange_operating_mic: "XLON")

    result = Import::SecurityMapping.mappables_by_key(@import)

    assert_equal aapl_other, result["AAPL"]
    assert_not_equal aapl_nasdaq, result["AAPL"]
  end

  test "mappables_by_key leaves a ticker unmatched when its rows disagree on exchange" do
    securities(:aapl)

    create_row(ticker: "AAPL", exchange_operating_mic: "XNAS")
    create_row(ticker: "AAPL", exchange_operating_mic: "XLON")

    result = Import::SecurityMapping.mappables_by_key(@import)

    assert_nil result["AAPL"], "ambiguous exchange should defer to the row-specific resolver"
  end

  test "values_count counts rows by ticker" do
    create_row(ticker: "AAPL")
    create_row(ticker: "AAPL")
    create_row(ticker: "MSFT")

    mapping = build_mapping(key: "AAPL")

    assert_equal 2, mapping.values_count
  end

  test "an unresolved mapping is invalid so the import cannot be published" do
    mapping = build_mapping(key: "VANGUARD TOTAL BOND ETF MARKET")

    assert_not mapping.valid?
    assert_includes mapping.errors.attribute_names, :mappable
  end

  test "a mapping with a resolved security is valid" do
    mapping = build_mapping(key: "AAPL")
    mapping.mappable = securities(:aapl)

    assert mapping.valid?
  end

  test "create_mappable! resolves a combobox value to a security" do
    msft = securities(:msft)
    resolver = mock
    resolver.stubs(:resolve).returns(msft)

    Security::Resolver.expects(:new)
                      .with("MSFT", exchange_operating_mic: "XNAS", price_provider: nil)
                      .returns(resolver)

    mapping = build_mapping(key: "MICROSOFT CORP", value: "MSFT|XNAS|")

    mapping.create_mappable!

    assert_equal msft, mapping.reload.mappable
  end

  test "create_mappable! is a no-op when value is blank" do
    mapping = build_mapping(key: "AAPL")

    Security::Resolver.expects(:new).never

    mapping.create_mappable!

    assert_nil mapping.reload.mappable
  end

  test "sync_mappings does not delete another import's security mappings" do
    other = TradeImport.create!(family: @import.family, status: :pending, date_format: "%Y-%m-%d")
    other_mapping = other.mappings.build(key: "KEEPME", type: "Import::SecurityMapping")
    other_mapping.save!(validate: false)

    create_row(ticker: "AAPL")
    @import.sync_mappings

    assert Import::SecurityMapping.exists?(other_mapping.id),
           "syncing one import must not prune another import's security mappings"
  end

  private
    def create_row(ticker:, exchange_operating_mic: nil)
      @import.rows.create!(
        source_row_number: @import.rows.count + 1,
        ticker: ticker,
        exchange_operating_mic: exchange_operating_mic.to_s,
        date: "2024-01-01",
        qty: "1",
        price: "100",
        currency: "USD"
      )
    end

    # Mirrors Import#sync_mappings, which persists mappings without validation
    # so unresolved rows can be collected before the user maps them.
    def build_mapping(key:, value: nil)
      mapping = @import.mappings.build(key: key, type: "Import::SecurityMapping", value: value)
      mapping.save!(validate: false)
      mapping
    end
end
