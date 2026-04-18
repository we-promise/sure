require "test_helper"

class TradeRepublic::SecurityResolverTest < ActiveSupport::TestCase
  setup do
    Holding.delete_all
    Security::Price.delete_all
    Trade.delete_all
    Security.delete_all
  end

  test "returns existing security by ISIN in name" do
    security = Security.create!(name: "Apple Inc. US0378331005", ticker: "AAPL1", exchange_operating_mic: "XNAS")
    resolver = TradeRepublic::SecurityResolver.new("US0378331005")
    assert_equal security, resolver.resolve
  end

  test "creates new security if not found" do
    resolver = TradeRepublic::SecurityResolver.new("US0000000001", name: "Test Security", ticker: "TEST1", mic: "XTST")
    security = resolver.resolve
    assert security.persisted?
    assert_equal "Test Security (US0000000001)", security.name
    assert_equal "TEST1", security.ticker
    assert_equal "XTST", security.exchange_operating_mic
  end

  test "returns existing security if ticker/mic already taken" do
    existing = Security.create!(name: "Existing", ticker: "DUPL1", exchange_operating_mic: "XDUP")
    resolver = TradeRepublic::SecurityResolver.new("US0000000002", name: "Other", ticker: "DUPL1", mic: "XDUP")
    assert_equal existing, resolver.resolve
  end
end
