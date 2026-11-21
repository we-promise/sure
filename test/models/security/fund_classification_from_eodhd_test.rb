require "test_helper"

class Security::FundClassificationFromEodhdTest < ActiveSupport::TestCase
  def run_eodhd(security, payload)
    provider = Provider::Eodhd.new("test_api_key")
    provider.stubs(:enforce_daily_limit!)
    provider.stubs(:throttle_request)
    provider.stubs(:client).returns(client = mock)
    client.stubs(:get).returns(stub(body: payload.to_json))
    security.stubs(:price_data_provider).returns(provider)
    security.import_provider_details(include_classification: true)
    security.reload
    [ security.asset_class, security.asset_sub_class, security.region, security.sector ]
  end

  def aa(h) = h.transform_values { |v| { "Net_Assets_%" => v.to_s } }
  def sec(t, mic, cc) = Security.create!(ticker: t, exchange_operating_mic: mic, country_code: cc)

  # Typical funds
  test "typical: S&P 500 ETF" do
    r = run_eodhd(sec("VOO", "ARCX", "US"), "General" => { "Type" => "ETF", "Name" => "VOO", "Category" => "Large Blend" },
      "ETF_Data" => { "Asset_Allocation" => aa("Stock US" => 99.4, "Stock non-US" => 0.5, "Cash" => 0.1),
                      "World_Regions" => { "North America" => { "Equity_%" => "99.5" }, "Europe Developed" => { "Equity_%" => "0.5" } },
                      "Sector_Weights" => { "Technology" => { "Equity_%" => "31" } } })
    assert_equal [ "equity", "etf", "north_america", nil ], r
  end

  test "typical: MSCI World on Xetra" do
    r = run_eodhd(sec("EUNL", "XETR", "DE"), "General" => { "Type" => "ETF", "Name" => "IWDA" },
      "ETF_Data" => { "Asset_Allocation" => aa("Stock US" => 70.1, "Stock non-US" => 29.6, "Cash" => 0.3),
                      "World_Regions" => { "North America" => { "Equity_%" => "73" }, "Europe Developed" => { "Equity_%" => "17" }, "Japan" => { "Equity_%" => "10" } } })
    assert_equal [ "equity", "etf", nil, nil ], r
  end

  test "typical: 60/40" do
    r = run_eodhd(sec("AOR", "ARCX", "US"), "General" => { "Type" => "ETF", "Name" => "AOR", "Category" => "Allocation--50% to 70% Equity" },
      "ETF_Data" => { "Asset_Allocation" => aa("Stock US" => 35, "Stock non-US" => 25, "Bond" => 39, "Cash" => 1) })
    assert_equal [ nil, "etf", nil, nil ], r
  end

  test "typical: gold ETF with category" do
    r = run_eodhd(sec("GLD", "ARCX", "US"), "General" => { "Type" => "ETF", "Name" => "GLD", "Category" => "Commodities Focused" },
      "ETF_Data" => { "Asset_Allocation" => aa("Other" => 100) })
    assert_equal [ "commodity", "etf", nil, nil ], r
  end

  test "typical: money market mutual fund" do
    r = run_eodhd(sec("VMFXX", "XNAS", "US"), "General" => { "Type" => "FUND", "Name" => "VMFXX" },
      "MutualFund_Data" => { "Fund_Category" => "Money Market-Taxable", "Asset_Allocation" => { "Cash" => { "Net_%" => "100" } } })
    assert_equal [ "liquidity", "mutual_fund", nil, nil ], r
  end

  test "typical: REIT ETF" do
    r = run_eodhd(sec("VNQ", "ARCX", "US"), "General" => { "Type" => "ETF", "Name" => "VNQ", "Category" => "Real Estate" },
      "ETF_Data" => { "Asset_Allocation" => aa("Stock US" => 99.0, "Cash" => 1.0),
                      "World_Regions" => { "North America" => { "Equity_%" => "100" } },
                      "Sector_Weights" => { "Real Estate" => { "Equity_%" => "99" } } })
    assert_equal [ "equity", "etf", "north_america", "Real Estate" ], r
  end

  # Edge cases in real fund data
  # Morningstar routinely reports a small negative cash line (pending settlement, TBA rolls)
  test "an S&P 500 ETF with a slightly negative cash line is still equity" do
    r = run_eodhd(sec("SPY", "ARCX", "US"), "General" => { "Type" => "ETF", "Name" => "SPY", "Category" => "Large Blend" },
      "ETF_Data" => { "Asset_Allocation" => aa("Stock US" => 99.6, "Stock non-US" => 0.5, "Cash" => -0.1),
                      "World_Regions" => { "North America" => { "Equity_%" => "99.5" } } })
    assert_equal [ "equity", "etf", "north_america", nil ], r
  end

  test "an aggregate bond ETF with negative cash (TBA rolls) is still fixed income" do
    r = run_eodhd(sec("AGG", "ARCX", "US"), "General" => { "Type" => "ETF", "Name" => "AGG", "Category" => "Intermediate Core Bond" },
      "ETF_Data" => { "Asset_Allocation" => aa("Bond" => 100.9, "Cash" => -1.2, "Other" => 0.3) })
    assert_equal [ "fixed_income", "etf", nil, nil ], r
  end

  # GDX holds gold-mining stocks; Morningstar category "Equity Precious Metals"
  test "a gold miners ETF is equity, not commodity" do
    r = run_eodhd(sec("GDX", "ARCX", "US"), "General" => { "Type" => "ETF", "Name" => "GDX", "Category" => "Equity Precious Metals" },
      "ETF_Data" => { "Asset_Allocation" => aa("Stock US" => 14.0, "Stock non-US" => 85.8, "Cash" => 0.2),
                      "Sector_Weights" => { "Basic Materials" => { "Equity_%" => "100" } } })
    assert_equal [ "equity", "etf" ], r[0, 2]
  end

  test "a null row in a MutualFund_Data list does not fail the whole lookup" do
    s = sec("VFIAX", "XNAS", "US")
    run_eodhd(s, "General" => { "Type" => "FUND", "Name" => "Vanguard 500 Admiral" },
      "MutualFund_Data" => { "Asset_Allocation" => { "US Stocks" => { "Net_%" => "99" } },
                             "World_Regions" => { "Americas" => [ nil, { "Name" => "North America", "Stocks_%" => "99" } ] } })
    assert_equal "Vanguard 500 Admiral", s.name
    assert_equal [ "equity", "mutual_fund", "north_america" ], [ s.asset_class, s.asset_sub_class, s.region ]
  end

  # EODHD also keys mutual-fund rows by index: the allocation at the top level,
  # and regions and sectors one level down, under their group.
  test "a mutual fund with indexed allocation, region and sector rows is classified" do
    r = run_eodhd(sec("VFIAX", "XNAS", "US"), "General" => { "Type" => "FUND", "Name" => "Vanguard 500 Admiral" },
      "MutualFund_Data" => {
        "Asset_Allocation" => { "0" => { "Type" => "Cash", "Net_%" => "0.4" }, "1" => { "Type" => "US Stocks", "Net_%" => "99.2" } },
        "World_Regions" => { "Americas" => { "0" => { "Name" => "North America", "Stocks_%" => "99.578" } } },
        "Sector_Weights" => { "Sensitive" => { "0" => { "Type" => "Technology", "Amount_%" => "95" } } }
      })
    assert_equal [ "equity", "mutual_fund", "north_america", "Technology" ], r
  end

  test "a money market fund named only in General.Fund_Category is liquidity" do
    r = run_eodhd(sec("SWVXX", "XNAS", "US"), "General" => { "Type" => "FUND", "Name" => "SWVXX", "Fund_Category" => "Money Market-Taxable" },
      "MutualFund_Data" => { "Asset_Allocation" => { "Cash" => { "Net_%" => "100" } } })
    assert_equal [ "liquidity", "mutual_fund", nil, nil ], r
  end
end
