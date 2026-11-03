require "test_helper"

class MoomooAccount::DataHelpersTest < ActiveSupport::TestCase
  class Host
    include MoomooAccount::DataHelpers

    public :parse_code, :importable_position?, :trade_date
  end

  setup do
    @helpers = Host.new
  end

  test "security codes map to a ticker, venue, currency and timezone" do
    {
      "HK.00700" => [ "0700", "XHKG", "HK", "HKD", "Asia/Hong_Kong" ],
      "HK.04321" => [ "4321", "XHKG", "HK", "HKD", "Asia/Hong_Kong" ],
      "HK.00005" => [ "0005", "XHKG", "HK", "HKD", "Asia/Hong_Kong" ],
      "HK.80737" => [ "80737", "XHKG", "HK", "HKD", "Asia/Hong_Kong" ],
      "US.AAPL" => [ "AAPL", nil, "US", "USD", "America/New_York" ],
      "US.PQR.B" => [ "PQR.B", nil, "US", "USD", "America/New_York" ],
      "SG.D05" => [ "D05", "XSES", "SG", "SGD", "Asia/Singapore" ],
      "SH.600519" => [ "600519", "XSHG", "CN", "CNH", "Asia/Shanghai" ],
      "SZ.000001" => [ "000001", "XSHE", "CN", "CNH", "Asia/Shanghai" ],
      "JP.7203" => [ "7203", "XJPX", "JP", "JPY", "Asia/Tokyo" ],
      "AU.BHP" => [ "BHP", "XASX", "AU", "AUD", "Australia/Sydney" ],
      "BMS.1155" => [ "1155", "XKLS", "MY", "MYR", "Asia/Kuala_Lumpur" ],
      "MY.1155" => [ "1155", "XKLS", "MY", "MYR", "Asia/Kuala_Lumpur" ],
      "KR.005930" => [ "005930", "XKRX", "KR", "KRW", "Asia/Seoul" ],
      "CA.SHOP" => [ "SHOP", nil, "CA", "CAD", "America/Toronto" ]
    }.each do |code, (ticker, mic, country, currency, timezone)|
      info = @helpers.parse_code(code)

      assert_equal [ ticker, mic, country, currency, timezone ], info.values_at(:ticker, :mic, :country, :currency, :tz), code
    end

    assert_nil @helpers.parse_code("XX.FOO")
    assert_nil @helpers.parse_code("AAPL")
    assert_nil @helpers.parse_code(nil)
  end

  test "only securities markets are queried for trades, in the order moomoo lists them" do
    assert_equal %w[SG US HK HKCC], MoomooAccount::DataHelpers.trd_markets_for([ 6, 2, 1, 4, 5, 7, 9 ])
    assert_equal %w[JP KR], MoomooAccount::DataHelpers.trd_markets_for([ "15", 18, 17 ])
  end

  test "an account that trades any securities market is a securities account" do
    assert_equal "securities", MoomooAccount::DataHelpers.account_kind_for([ 1, 2, 5, 7 ])
    assert_equal "futures", MoomooAccount::DataHelpers.account_kind_for([ 5 ])
    assert_equal "crypto", MoomooAccount::DataHelpers.account_kind_for([ 7 ])
    assert_equal "other", MoomooAccount::DataHelpers.account_kind_for([ 9, 14 ])
    assert_equal "other", MoomooAccount::DataHelpers.account_kind_for(nil)
  end

  test "moomoo Japan margin and derivative accounts are not securities accounts yet" do
    assert_equal "jp_margin", MoomooAccount::DataHelpers.account_kind_for([ 15, 2 ], security_firm: "FUTUJP", acc_type: "margin")
    assert_equal "jp_margin", MoomooAccount::DataHelpers.account_kind_for([ 15 ], security_firm: "FUTUJP", acc_type: "Derivative")
    assert_equal "securities", MoomooAccount::DataHelpers.account_kind_for([ 15 ], security_firm: "FUTUJP", acc_type: "cash")
    assert_equal "securities", MoomooAccount::DataHelpers.account_kind_for([ 6, 2 ], security_firm: "FUTUSG", acc_type: "margin")
  end

  test "long stock and fund positions are importable" do
    assert @helpers.importable_position?({ "position_side" => "LONG", "security_type" => "STOCK", "qty" => "10", "code" => "SG.D05" })
    assert @helpers.importable_position?({ "security_type" => "FUND", "qty" => "3.5", "code" => "MMF.123" })
    assert @helpers.importable_position?({ "position_side" => "LONG", "qty" => "100", "code" => "US.AAPL" })

    assert_not @helpers.importable_position?({ "position_side" => "SHORT", "security_type" => "STOCK", "qty" => "10", "code" => "US.AAPL" })
    assert_not @helpers.importable_position?({ "position_side" => "LONG", "security_type" => "OPTION", "qty" => "1", "code" => "US.AAPL240119C190000" })
    assert_not @helpers.importable_position?({ "position_side" => "LONG", "qty" => "1", "code" => "US.AAPL240119C190000" })
    assert_not @helpers.importable_position?({ "position_side" => "LONG", "security_type" => "STOCK", "qty" => "0", "code" => "US.AAPL" })
  end

  test "trade dates are in the market's timezone" do
    micros = Provider::Moomoo.to_micros(Time.utc(2026, 3, 3, 2, 0))

    assert_equal Date.new(2026, 3, 2), @helpers.trade_date(micros, "America/New_York")
    assert_equal Date.new(2026, 3, 3), @helpers.trade_date(micros, "Asia/Singapore")
    assert_nil @helpers.trade_date(nil, "Asia/Singapore")
  end
end
