require "test_helper"

class SecuritiesControllerTest < ActionDispatch::IntegrationTest
  setup { sign_in users(:family_admin) }

  test "index shows the ISIN of a search result when the provider returns one" do
    with_isin = Security.new(ticker: "SGLD", name: "Invesco Physical Gold", exchange_operating_mic: "XLON",
                             country_code: "GB", price_provider: "eodhd")
    with_isin.search_isin = "IE00B579F325"
    without_isin = Security.new(ticker: "PHYM", name: "Another fund", exchange_operating_mic: "XLON",
                                country_code: "GB", price_provider: "yahoo_finance")
    Security.stubs(:search_provider).returns([ with_isin, without_isin ])

    get securities_url(q: "gold"), as: :turbo_stream

    assert_response :success
    assert_equal 1, response.body.scan("IE00B579F325").size
    assert_includes response.body, "Another fund"
  end
end
