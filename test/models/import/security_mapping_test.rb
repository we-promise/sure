require "test_helper"

class Import::SecurityMappingTest < ActiveSupport::TestCase
  setup do
    @import = imports(:trade)
    @import.update!(date_format: "%Y-%m-%d")
  end

  test "key_for composes ticker and canonical MIC" do
    assert_equal "AAPL", Import::SecurityMapping.key_for(ticker: " aapl ", exchange_operating_mic: nil)
    assert_equal "AAPL|XNAS", Import::SecurityMapping.key_for(ticker: "aapl", exchange_operating_mic: "xnas")
  end

  test "mappables_by_key auto-matches a seeded security by ticker and leaves unknown labels unmatched" do
    aapl = securities(:aapl)

    create_row(ticker: "AAPL")
    create_row(ticker: "VANGUARD TOTAL BOND ETF MARKET")

    result = Import::SecurityMapping.mappables_by_key(@import)

    assert_equal aapl, result["AAPL"]
    assert_nil result["VANGUARD TOTAL BOND ETF MARKET"]
  end

  test "mappables_by_key matches the row exchange when a MIC is given" do
    aapl_nasdaq = securities(:aapl) # XNAS
    aapl_other = Security.create!(ticker: "AAPL", exchange_operating_mic: "XLON", name: "Apple LSE")

    create_row(ticker: "AAPL", exchange_operating_mic: "XLON")

    result = Import::SecurityMapping.mappables_by_key(@import)

    assert_equal aapl_other, result["AAPL|XLON"]
    assert_not_equal aapl_nasdaq, result["AAPL|XLON"]
  end

  test "mappables_by_key keeps same-ticker-different-MIC rows as distinct mappings" do
    securities(:aapl) # XNAS
    aapl_lse = Security.create!(ticker: "AAPL", exchange_operating_mic: "XLON", name: "Apple LSE")

    create_row(ticker: "AAPL", exchange_operating_mic: "XNAS")
    create_row(ticker: "AAPL", exchange_operating_mic: "XLON")

    result = Import::SecurityMapping.mappables_by_key(@import)

    assert_equal %w[AAPL|XNAS AAPL|XLON].sort, result.keys.sort
    assert_equal securities(:aapl), result["AAPL|XNAS"]
    assert_equal aapl_lse, result["AAPL|XLON"]
  end

  test "mappables_by_key does not auto-pick when MIC is absent and multiple local listings exist" do
    securities(:aapl) # XNAS
    Security.create!(ticker: "AAPL", exchange_operating_mic: "XLON", name: "Apple LSE")

    create_row(ticker: "AAPL") # no MIC

    result = Import::SecurityMapping.mappables_by_key(@import)

    assert_nil result["AAPL"], "ambiguous ticker with no MIC must not auto-pick a listing"
  end

  test "mappable_for_row resolves through the row's own composite key" do
    aapl = securities(:aapl)
    row = create_row(ticker: "AAPL", exchange_operating_mic: "XNAS")
    build_mapping(key: "AAPL|XNAS", mappable: aapl)

    assert_equal aapl, Import::SecurityMapping.mappable_for_row(@import, row)
  end

  test "values_count counts rows matching the composite key" do
    create_row(ticker: "AAPL", exchange_operating_mic: "XNAS")
    create_row(ticker: "AAPL", exchange_operating_mic: "XNAS")
    create_row(ticker: "AAPL", exchange_operating_mic: "XLON")

    mapping = build_mapping(key: "AAPL|XNAS")

    assert_equal 2, mapping.values_count
  end

  test "an unresolved descriptive label is invalid so the import cannot be published" do
    mapping = build_mapping(key: "VANGUARD TOTAL BOND ETF MARKET")

    assert_not mapping.valid?
    assert_includes mapping.errors.attribute_names, :mappable
  end

  test "an unresolved but plausible ticker stays valid so import! can resolve it directly" do
    mapping = build_mapping(key: "TSLA")

    assert mapping.valid?, "a clean, resolvable ticker must not force manual selection"
  end

  test "a mapping with a resolved security is valid" do
    mapping = build_mapping(key: "VANGUARD TOTAL BOND ETF MARKET", mappable: securities(:aapl))

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

  test "create_mappable! clears a stale mappable when the value is cleared" do
    mapping = build_mapping(key: "AAPL|XNAS", mappable: securities(:aapl))
    mapping.update_column(:value, "")

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
    def build_mapping(key:, value: nil, mappable: nil)
      mapping = @import.mappings.build(key: key, type: "Import::SecurityMapping", value: value, mappable: mappable)
      mapping.save!(validate: false)
      mapping
    end
end
