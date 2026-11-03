require "test_helper"

class EtoroDataHelpersTest < ActiveSupport::TestCase
  # Resolves instruments the way the account processors do, from a given
  # instruments map.
  class Host
    include EtoroAccount::DataHelpers

    attr_reader :instruments_map
    attr_writer :etoro_account

    def initialize(instruments_map)
      @instruments_map = instruments_map
    end

    def security(instrument_id) = security_for_instrument(instrument_id)

    def date(value) = parse_date(value)
  end

  test "a US stock resolves on its exchange" do
    expect_listing("AAPL", "XNAS")

    assert_equal securities(:aapl), security({ "symbol" => "AAPL", "type_id" => 5, "exchange_id" => 4 })
  end

  test "a venue suffix gives way to the exchange's MIC" do
    londa = expect_listing("LNDA", "XLON")

    assert_equal londa, security({ "symbol" => "LNDA.L", "type_id" => 5, "exchange_id" => 7 })
  end

  test "the venue suffix decides when the exchange is unknown" do
    milx = expect_listing("MILX", "XMIL")

    assert_equal milx, security({ "symbol" => "MILX.MI", "type_id" => 5 })
  end

  test "eToro's own suffixes on US listings are dropped" do
    us_line = expect_listing("EFGH", "XNYS")
    ch_line = expect_listing("IJKL", "XNYS")

    assert_equal us_line, security({ "symbol" => "EFGH.US", "type_id" => 5, "exchange_id" => 5 })
    assert_equal ch_line, security({ "symbol" => "IJKL.CH", "type_id" => 5, "exchange_id" => 5 })
  end

  test "a regular-trading-hours line resolves to the plain listing's security" do
    listed = expect_listing("ABCD", "XNAS")
    host = Host.new(
      "1" => { "symbol" => "ABCD", "type_id" => 5, "exchange_id" => 4 },
      "2" => { "symbol" => "ABCD.RTH", "type_id" => 5, "exchange_id" => 33 }
    )

    assert_equal listed, host.security(1)
    assert_equal listed, host.security(2)
  end

  test "a share class stays in the ticker" do
    share_class = expect_listing("PQR.B", "XNYS")

    assert_equal share_class, security({ "symbol" => "PQR.B", "type_id" => 5, "exchange_id" => 5 })
  end

  test "a regular-trading-hours line of a share class resolves to the share class" do
    share_class = expect_listing("PQR.B", "XNYS")
    host = Host.new(
      "1" => { "symbol" => "PQR.B", "type_id" => 5, "exchange_id" => 5 },
      "2" => { "symbol" => "PQR.B.RTH", "type_id" => 5, "exchange_id" => 33 }
    )

    assert_equal share_class, host.security(1)
    assert_equal share_class, host.security(2)
  end

  test "eToro's suffix after a share class is dropped and the class kept" do
    share_class = expect_listing("PQR.B", "XNYS")

    assert_equal share_class, security({ "symbol" => "PQR.B.US", "type_id" => 5, "exchange_id" => 5 })
  end

  test "a venue suffix after a share class keeps the class in the ticker" do
    qrs = expect_listing("QRS.A", "XLON")

    assert_equal qrs, security({ "symbol" => "QRS.A.L", "type_id" => 5, "exchange_id" => 7 })
  end

  test "a line outside the US never resolves to a listing in another country" do
    provider_lists("QZX", "XLON", [ provider_line("QZX", "XNYS", "US"), provider_line("QZX.L", "XLON", "GB") ])

    london = security({ "symbol" => "QZX.L", "name" => "Qzx Defence", "type_id" => 5, "exchange_id" => 7 })

    assert_equal [ "QZX", "XLON", "GB" ], [ london.ticker, london.exchange_operating_mic, london.country_code ]
    assert_equal "Qzx Defence", london.name
    assert_equal "yahoo_finance", london.price_provider
    assert_not london.offline?
    assert_nil Security.find_by(ticker: "QZX", exchange_operating_mic: "XNYS"), "the New York line the resolver saved is not left behind"
  end

  test "a listing in another country that already existed stays when eToro passes it over" do
    new_york = Security.create!(ticker: "QZX", name: "Qzx Aircraft", exchange_operating_mic: "XNYS", country_code: "US")
    provider_lists("QZX", "XLON", [ provider_line("QZX", "XNYS", "US"), provider_line("QZX.L", "XLON", "GB") ])

    london = security({ "symbol" => "QZX.L", "name" => "Qzx Defence", "type_id" => 5, "exchange_id" => 7 })

    assert_equal "XLON", london.exchange_operating_mic
    assert Security.exists?(new_york.id)
  end

  test "a provider's own line on the venue counts even under an exchange code it does not map" do
    provider_lists("STU", "XETR", [ provider_line("STU", "XNYS", "US"), provider_line("STU.DE", "GER", "DE") ])

    venue_line = security({ "symbol" => "STU.DE", "name" => "Stu AG", "type_id" => 5, "exchange_id" => 6 })

    assert_equal [ "STU", "XETR", "DE" ], [ venue_line.ticker, venue_line.exchange_operating_mic, venue_line.country_code ]
    assert_equal "Stu AG", venue_line.name
    assert_not venue_line.offline?
  end

  test "a line no provider lists on its venue is kept there offline" do
    provider_lists("NOPQ", "XETR", [ provider_line("NOPQ", "XNYS", "US") ])

    nopq = security({ "symbol" => "NOPQ.DE", "name" => "Nopq SE", "type_id" => 5, "exchange_id" => 6 })

    assert_equal [ "NOPQ", "XETR" ], [ nopq.ticker, nopq.exchange_operating_mic ]
    assert_equal "Nopq SE", nopq.name
    assert nopq.offline?
    assert_nil Security.find_by(ticker: "NOPQ", exchange_operating_mic: "XNYS"), "the New York line the resolver saved is not left behind"
  end

  test "a US line keeps its US listing" do
    provider_lists("QZX", "XNYS", [ provider_line("QZX", "XNYS", "US"), provider_line("QZX.L", "XLON", "GB") ])

    new_york = security({ "symbol" => "QZX", "name" => "Qzx Aircraft", "type_id" => 5, "exchange_id" => 5 })

    assert_equal [ "QZX", "XNYS" ], [ new_york.ticker, new_york.exchange_operating_mic ]
  end

  test "eToro's timestamps are dated by their UTC day whatever the zone" do
    host = Host.new({})

    Time.use_zone("Asia/Singapore") { assert_equal Date.new(2026, 2, 10), host.date("2026-02-10T20:00:00Z") }
    Time.use_zone("America/Los_Angeles") { assert_equal Date.new(2026, 3, 1), host.date("2026-03-01T05:00:00Z") }
    assert_equal Date.new(2026, 1, 10), host.date("2026-01-10")
  end

  test "Dubai listings resolve on the DFM" do
    first_line = expect_listing("DXBA", "XDFM")
    second_line = expect_listing("DXBB", "XDFM")

    assert_equal first_line, security({ "symbol" => "DXBA.AE", "type_id" => 5, "exchange_id" => 39 })
    assert_equal second_line, security({ "symbol" => "DXBB.AE", "type_id" => 5 })
  end

  test "crypto resolves to the shared crypto security without a provider search" do
    Security.expects(:search_provider).never

    coin = security({ "symbol" => "XCN", "name" => "Examplecoin", "type_id" => 10 })

    assert_equal "CRYPTO:XCN", coin.ticker
    assert_equal Onchain::SecurityResolver::EXCHANGE_MIC, coin.exchange_operating_mic
    assert_equal Onchain::SecurityResolver::PRICE_PROVIDER, coin.price_provider
    assert_equal "Examplecoin", coin.name
  end

  test "crypto reuses the crypto security another integration created" do
    existing = Security.create!(ticker: "CRYPTO:YCN", name: "Othercoin", exchange_operating_mic: Onchain::SecurityResolver::EXCHANGE_MIC)

    assert_equal existing, security({ "symbol" => "YCN", "type_id" => 10 })
  end

  test "an instrument without a symbol becomes an offline security with eToro's name" do
    placeholder = security({ "name" => "Some Fund", "type_id" => 6 }, id: 2003)

    assert_equal "ETORO:2003", placeholder.ticker
    assert placeholder.offline?
    assert_equal "Some Fund", placeholder.name
  end

  test "a security no provider prices takes eToro's name" do
    Security.stubs(:search_provider).returns([])

    londa = security({ "symbol" => "LNDA.L", "name" => "Londa Group", "type_id" => 5, "exchange_id" => 7 })

    assert_equal "LNDA", londa.ticker
    assert_equal "XLON", londa.exchange_operating_mic
    assert londa.offline?
    assert_equal "Londa Group", londa.name
  end

  test "a security a provider matched keeps its own description" do
    matched = Security.create!(ticker: "NOPQ", exchange_operating_mic: "XETR")
    Security::Resolver.expects(:new).with("NOPQ", exchange_operating_mic: "XETR").returns(stub(resolve: matched))

    security({ "symbol" => "NOPQ.DE", "name" => "Nopq SE", "type_id" => 5, "exchange_id" => 6 })

    assert_nil matched.reload.name
  end

  test "an instrument eToro has not described resolves to nothing" do
    Security::Resolver.expects(:new).never

    assert_nil Host.new({}).security(4242)
  end

  test "with its own securities, a US stock becomes eToro's own security on its exchange, no provider asked" do
    Security::Resolver.expects(:new).never
    Security.expects(:search_provider).never
    host = own_host("1" => { "symbol" => "AAPL", "name" => "Apple Inc", "type_id" => 5, "exchange_id" => 4 })

    own = host.security(1)

    assert_equal [ "ETORO:AAPL", "XNAS", "US", "Apple Inc" ], [ own.ticker, own.exchange_operating_mic, own.country_code, own.name ]
    assert own.offline?
    assert_equal EtoroAccount::PriceHistoryProcessor::OFFLINE_REASON, own.offline_reason
    assert_nil own.price_provider
    assert EtoroAccount::PriceHistoryProcessor.priceable?(own)
    assert_equal securities(:aapl), Security.find_by(ticker: "AAPL", exchange_operating_mic: "XNAS"), "the shared security stays as it was"
  end

  test "with its own securities, a venue line keeps its venue, and the lines eToro lists beside a listing resolve to the listing's own security" do
    host = own_host(
      "1" => { "symbol" => "LNDA.L", "name" => "Londa Group", "type_id" => 5, "exchange_id" => 7 },
      "2" => { "symbol" => "ABCD", "type_id" => 5, "exchange_id" => 4 },
      "3" => { "symbol" => "ABCD.RTH", "type_id" => 5, "exchange_id" => 33 }
    )

    londa = host.security(1)
    assert_equal [ "ETORO:LNDA", "XLON", "GB" ], [ londa.ticker, londa.exchange_operating_mic, londa.country_code ]
    assert_equal host.security(2), host.security(3)
    assert_equal "ETORO:ABCD", host.security(2).ticker
  end

  test "with its own securities, crypto is eToro's own too, apart from the shared crypto security" do
    host = own_host("1" => { "symbol" => "XCN", "name" => "Examplecoin", "type_id" => 10 })

    coin = host.security(1)

    assert_equal [ "ETORO:XCN", nil, "Examplecoin" ], [ coin.ticker, coin.exchange_operating_mic, coin.name ]
    assert coin.offline?
    assert_not coin.crypto?
    assert_nil Security.find_by(ticker: "CRYPTO:XCN")
  end

  test "an own security is reused with its name, and an instrument without a symbol still gets its placeholder" do
    existing = Security.create!(ticker: "ETORO:ABCD", name: "Abcd, as named", exchange_operating_mic: "XNAS", offline: true)
    host = own_host(
      "1" => { "symbol" => "ABCD", "name" => "Abcd Inc", "type_id" => 5, "exchange_id" => 4 },
      "2" => { "name" => "Some Fund", "type_id" => 6 }
    )

    assert_equal existing, host.security(1)
    assert_equal "Abcd, as named", existing.reload.name
    assert_equal "ETORO:2", host.security(2).ticker
  end

  private

    def own_host(instruments)
      etoro_account = etoro_accounts(:main_account)
      etoro_account.etoro_item.update!(own_securities: true)
      host = Host.new(instruments)
      host.etoro_account = etoro_account
      host
    end

    def security(instrument, id: 1)
      Host.new(id.to_s => instrument).security(id)
    end

    def expect_listing(ticker, mic)
      listed = Security.find_by(ticker: ticker, exchange_operating_mic: mic) ||
        Security.create!(ticker: ticker, name: ticker, exchange_operating_mic: mic)
      Security::Resolver.stubs(:new).with(ticker, exchange_operating_mic: mic).returns(stub(resolve: listed))
      listed
    end

    # What the securities provider's search returns for a ticker on a venue,
    # whether the resolver asks (with its technical_failure callback) or the
    # venue check does.
    def provider_lists(ticker, mic, lines)
      Security.stubs(:search_provider)
        .with { |symbol, **options| symbol == ticker && options[:exchange_operating_mic] == mic }
        .returns(lines)
    end

    # A search result shaped like Yahoo Finance's, which names lines outside
    # the US with a venue suffix and leaves some exchange codes unmapped.
    def provider_line(ticker, mic, country)
      Security.new(ticker: ticker, exchange_operating_mic: mic, country_code: country, price_provider: "yahoo_finance")
    end
end
