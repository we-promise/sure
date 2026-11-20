require "test_helper"

# ETFs and funds are classified from their category or what they hold
# (`fund_weights`). A fund's region comes from its equity holdings, not from
# the listing country; a stock keeps its listing region.
class Security::FundClassificationTest < ActiveSupport::TestCase
  include ProviderTestHelper

  setup do
    # A UCITS ETF listed on Xetra: the defaults derive "europe" from DE.
    @security = Security.create!(ticker: "VWCE", exchange_operating_mic: "XETR", country_code: "DE")
  end

  test "the listing country gives a fund a default region before the provider answers" do
    assert_equal "europe", @security.region
  end

  test "an equity ETF is classified from its holdings" do
    import(info(kind: "ETF", fund_weights: { asset_class: { "equity" => 99.2, "liquidity" => 0.8 } }))

    assert_equal "equity", @security.reload.asset_class
    assert_equal "etf", @security.asset_sub_class
    assert_equal "provider", @security.classification_source
  end

  test "a bond ETF is classified as fixed income" do
    import(info(kind: "ETF", fund_weights: { asset_class: { "fixed_income" => 97.5, "liquidity" => 2.5 } }))

    assert_equal "fixed_income", @security.reload.asset_class
    assert_equal "etf", @security.asset_sub_class
  end

  test "a fund is classified as a mutual fund" do
    import(info(kind: "FUND", fund_weights: { asset_class: { "equity" => 95.0, "liquidity" => 5.0 } }))

    assert_equal "equity", @security.reload.asset_class
    assert_equal "mutual_fund", @security.asset_sub_class
  end

  test "a balanced fund has no single asset class, so it is left unclassified" do
    import(info(kind: "FUND", fund_weights: { asset_class: { "equity" => 60.0, "fixed_income" => 40.0 } }))

    assert_nil @security.reload.asset_class
    assert_nil @security.classification_source
  end

  # The wrapper is known even when nothing settles the class, and it keeps the
  # listing country from setting the fund's region.
  test "a fund with no class answer still gets its sub-class and loses its listing region" do
    import(info(kind: "ETF"))

    assert_nil @security.reload.asset_class
    assert_equal "etf", @security.asset_sub_class
    assert_nil @security.classification_source, "a sub-class alone is not a classification"
    assert_nil @security.region

    @security.update!(name: "Vanguard FTSE All-World")
    assert_nil @security.reload.region, "the listing region was put back on a later save"
  end

  # A region derived from the listing still follows a corrected listing
  # country, fund or not; only a blank region stays blank for a fund.
  test "a fund's listing region follows a country correction" do
    @security.update!(asset_sub_class: "etf", classification_source: "manual")
    assert_equal "europe", @security.region

    @security.update!(country_code: "US")

    assert_equal "north_america", @security.reload.region
  end

  test "a world ETF does not keep the region of the exchange it is listed on" do
    import(info(kind: "ETF", fund_weights: {
      asset_class: { "equity" => 99.6 },
      equity_region: { "north_america" => 64.0, "europe" => 15.0, "asia_pacific" => 21.0 }
    }))

    assert_nil @security.reload.region

    @security.update!(name: "Vanguard FTSE All-World")
    assert_nil @security.reload.region, "the listing region was put back on a later save"
  end

  test "an ETF that holds one region gets that region" do
    import(info(kind: "ETF", fund_weights: {
      asset_class: { "equity" => 99.9 },
      equity_region: { "north_america" => 99.4, "europe" => 0.6 }
    }))

    assert_equal "north_america", @security.reload.region
  end

  test "a sector ETF gets its sector, a broad one does not" do
    import(info(kind: "ETF", fund_weights: { asset_class: { "equity" => 99.0 }, equity_sector: { "Technology" => 98.0, "Industrials" => 2.0 } }))
    assert_equal "Technology", @security.reload.sector

    broad = Security.create!(ticker: "IWDA", exchange_operating_mic: "XAMS", country_code: "NL")
    import(info(kind: "ETF", fund_weights: { asset_class: { "equity" => 99.0 }, equity_sector: { "Technology" => 25.0, "Healthcare" => 12.0 } }), security: broad)
    assert_nil broad.reload.sector
  end

  test "a manual classification is not replaced by a fund's holdings" do
    @security.update!(asset_class: "alternative_investment", asset_sub_class: "etf", classification_source: "manual", region: "asia_pacific")

    import(info(kind: "ETF", fund_weights: { asset_class: { "equity" => 99.0 }, equity_region: { "north_america" => 99.0 } }))

    assert_equal "alternative_investment", @security.reload.asset_class
    assert_equal "asia_pacific", @security.region
  end

  test "a region someone set by hand is kept" do
    @security.update!(region: "middle_east_africa")

    import(info(kind: "ETF", fund_weights: { asset_class: { "equity" => 99.0 }, equity_region: { "north_america" => 99.0 } }))

    assert_equal "equity", @security.reload.asset_class
    assert_equal "middle_east_africa", @security.region
  end

  # SH: a short stock position plus cash collateral above 100%.
  test "an inverse ETF is left unclassified" do
    sh = Security.create!(ticker: "SH", exchange_operating_mic: "ARCX", country_code: "US")
    import(info(kind: "ETF", fund_weights: eodhd_weights("Asset_Allocation" => {
      "Stock US" => { "Net_Assets_%" => "-100.2" }, "Cash" => { "Net_Assets_%" => "200.2" }
    })), security: sh)

    assert_nil sh.reload.asset_class
    assert_equal "etf", sh.asset_sub_class
    assert_nil sh.region, "an inverse ETF's listing says nothing about its exposure"
  end

  test "a fund whose category says leveraged or inverse is left unclassified" do
    import(info(kind: "ETF", fund_weights: eodhd_weights(
      { "Asset_Allocation" => { "Stock US" => { "Net_Assets_%" => "99.0" } } },
      "Trading--Leveraged Equity"
    )))

    assert_nil @security.reload.asset_class
  end

  test "weights that are not plain long holdings leave a fund unclassified" do
    import(info(kind: "ETF", fund_weights: { asset_class: { "equity" => 200.0, "liquidity" => -100.0 } }))

    assert_nil @security.reload.asset_class
  end

  # DBC, USO: futures exposure, T-bills and cash as collateral.
  test "a commodity ETF that holds mostly cash is not classified as liquidity" do
    dbc = Security.create!(ticker: "DBC", exchange_operating_mic: "ARCX", country_code: "US")
    import(info(kind: "ETF", fund_weights: eodhd_weights("Asset_Allocation" => {
      "Cash" => { "Net_Assets_%" => "92.0" }, "Other" => { "Net_Assets_%" => "8.0" }
    })), security: dbc)

    assert_nil dbc.reload.asset_class
  end

  test "a fund's category decides its class over its holdings" do
    dbc = Security.create!(ticker: "DBC", exchange_operating_mic: "ARCX", country_code: "US")
    import(info(kind: "ETF", fund_weights: eodhd_weights(
      { "Asset_Allocation" => { "Cash" => { "Net_Assets_%" => "92.0" }, "Bond" => { "Net_Assets_%" => "8.0" } } },
      "Commodities Broad Basket"
    )), security: dbc)

    assert_equal [ "commodity", "etf", nil ], [ dbc.reload.asset_class, dbc.asset_sub_class, dbc.region ]

    mmf = Security.create!(ticker: "VMFXX", exchange_operating_mic: "XNAS", country_code: "US")
    import(info(kind: "FUND", fund_weights: eodhd_weights(
      { "Asset_Allocation" => { "Cash" => { "Net_%" => "97.0" }, "Bonds" => { "Net_%" => "3.0" } } },
      "Money Market-Taxable"
    )), security: mmf)

    assert_equal [ "liquidity", "mutual_fund" ], [ mmf.reload.asset_class, mmf.asset_sub_class ]
  end

  # World_Regions and Sector_Weights are percentages of the equity sleeve.
  test "a bond fund's region and sector do not come from a small equity sleeve" do
    aggg = Security.create!(ticker: "AGGG", exchange_operating_mic: "XLON", country_code: "GB")
    import(info(kind: "ETF", fund_weights: eodhd_weights(
      "Asset_Allocation" => { "Bond" => { "Net_Assets_%" => "98.0" }, "Stock US" => { "Net_Assets_%" => "1.0" }, "Cash" => { "Net_Assets_%" => "1.0" } },
      "World_Regions" => { "North America" => { "Equity_%" => "100" } },
      "Sector_Weights" => { "Energy" => { "Equity_%" => "100" } }
    )), security: aggg)

    aggg.reload
    assert_equal "fixed_income", aggg.asset_class
    assert_nil aggg.region
    assert_nil aggg.sector
  end

  test "an unclassified fund takes neither its listing region nor its equity sleeve's" do
    import(info(kind: "ETF", fund_weights: eodhd_weights(
      "Asset_Allocation" => { "Stock US" => { "Net_Assets_%" => "60.0" }, "Bond" => { "Net_Assets_%" => "40.0" } },
      "World_Regions" => { "North America" => { "Equity_%" => "100" } }
    )))

    assert_nil @security.reload.asset_class
    assert_nil @security.region
  end

  # Accenture, Medtronic, Eaton: US-listed and US-run, incorporated in Ireland.
  test "a stock keeps the region of its listing, not its country of incorporation" do
    acn = Security.create!(ticker: "ACN", exchange_operating_mic: "XNYS", country_code: "US")
    provider = Provider::Eodhd.new("test_api_key")
    provider.stubs(:enforce_daily_limit!)
    provider.stubs(:throttle_request)
    provider.stubs(:client).returns(client = mock)
    client.stubs(:get).returns(stub(body: {
      "General" => { "Name" => "Accenture plc", "Type" => "Common Stock", "CountryISO" => "IE", "Sector" => "Technology" }
    }.to_json))
    acn.stubs(:price_data_provider).returns(provider)

    acn.import_provider_details(include_classification: true)

    assert_equal [ "equity", "stock", "north_america" ], [ acn.reload.asset_class, acn.asset_sub_class, acn.region ]
  end

  private
    def eodhd_weights(etf_data, category = nil)
      provider = Provider::Eodhd.new("test_api_key")
      category ? provider.send(:fund_weights_from, etf_data, category: category) : provider.send(:fund_weights_from, etf_data)
    end

    def info(kind:, fund_weights: nil, sector: nil)
      Provider::SecurityConcept::SecurityInfo.new(
        symbol: "X", name: nil, links: nil, logo_url: nil, description: nil, kind: kind,
        exchange_operating_mic: nil, sector: sector, industry: nil, fund_weights: fund_weights
      )
    end

    def import(data, security: @security)
      provider = capable_provider("provider")
      provider.stubs(:class).returns(Provider::TwelveData)
      provider.stubs(:fetch_security_info).returns(provider_success_response(data))
      security.stubs(:price_data_provider).returns(provider)
      security.import_provider_details(include_classification: true)
    end
end
