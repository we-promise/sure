require "test_helper"

# ETFs and funds are classified from what they hold (`fund_weights`), and a
# region comes from the issuer or the holdings, not from the listing country.
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

  test "a world ETF does not keep the region of the exchange it is listed on" do
    import(info(kind: "ETF", fund_weights: {
      asset_class: { "equity" => 99.6 },
      region: { "north_america" => 64.0, "europe" => 15.0, "asia_pacific" => 21.0 }
    }))

    assert_nil @security.reload.region

    @security.update!(name: "Vanguard FTSE All-World")
    assert_nil @security.reload.region, "the listing region was put back on a later save"
  end

  test "an ETF that holds one region gets that region" do
    import(info(kind: "ETF", fund_weights: {
      asset_class: { "equity" => 99.9 },
      region: { "north_america" => 99.4, "europe" => 0.6 }
    }))

    assert_equal "north_america", @security.reload.region
  end

  test "a sector ETF gets its sector, a broad one does not" do
    import(info(kind: "ETF", fund_weights: { asset_class: { "equity" => 99.0 }, sector: { "Technology" => 98.0, "Industrials" => 2.0 } }))
    assert_equal "Technology", @security.reload.sector

    broad = Security.create!(ticker: "IWDA", exchange_operating_mic: "XAMS", country_code: "NL")
    import(info(kind: "ETF", fund_weights: { asset_class: { "equity" => 99.0 }, sector: { "Technology" => 25.0, "Healthcare" => 12.0 } }), security: broad)
    assert_nil broad.reload.sector
  end

  test "a manual classification is not replaced by a fund's holdings" do
    @security.update!(asset_class: "alternative_investment", asset_sub_class: "etf", classification_source: "manual", region: "asia_pacific")

    import(info(kind: "ETF", fund_weights: { asset_class: { "equity" => 99.0 }, region: { "north_america" => 99.0 } }))

    assert_equal "alternative_investment", @security.reload.asset_class
    assert_equal "asia_pacific", @security.region
  end

  test "a stock's region is its issuer's country, not its listing's" do
    adr = Security.create!(ticker: "BABA", exchange_operating_mic: "XNYS", country_code: "US")
    assert_equal "north_america", adr.region

    import(info(kind: "Common Stock", issuer_country_code: "CN"), security: adr)

    assert_equal "asia_pacific", adr.reload.region
    assert_equal "equity", adr.asset_class
  end

  test "a region someone set by hand is kept" do
    stock = Security.create!(ticker: "SHEL", exchange_operating_mic: "XLON", country_code: "GB", region: "middle_east_africa")

    import(info(kind: "Common Stock", issuer_country_code: "GB"), security: stock)

    assert_equal "middle_east_africa", stock.reload.region
  end

  test "an issuer country the region list does not name keeps the listing region" do
    stock = Security.create!(ticker: "XYZ", exchange_operating_mic: "XNYS", country_code: "US")

    import(info(kind: "Common Stock", issuer_country_code: "ZZ"), security: stock)

    assert_equal "north_america", stock.reload.region
  end

  private
    def info(kind:, fund_weights: nil, issuer_country_code: nil, sector: nil)
      Provider::SecurityConcept::SecurityInfo.new(
        symbol: "X", name: nil, links: nil, logo_url: nil, description: nil, kind: kind,
        exchange_operating_mic: nil, sector: sector, industry: nil,
        issuer_country_code: issuer_country_code, fund_weights: fund_weights
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
