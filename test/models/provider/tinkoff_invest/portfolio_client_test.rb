require "test_helper"

class Provider::TinkoffInvest::PortfolioClientTest < ActiveSupport::TestCase
  LIVE_API = Provider::TinkoffInvest::PortfolioClient::LIVE_BASE_URL
  SANDBOX_API = Provider::TinkoffInvest::PortfolioClient::SANDBOX_BASE_URL
  NS = Provider::TinkoffInvest::API_NS

  setup do
    Rails.cache.clear
    @client = Provider::TinkoffInvest::PortfolioClient.new(api_key: "secret-test-token")
    @client.stubs(:throttle_request)
  end

  test "requires a non-blank API token" do
    assert_raises(Provider::TinkoffInvest::PortfolioClient::ConfigurationError) do
      Provider::TinkoffInvest::PortfolioClient.new(api_key: "  ")
    end
  end

  test "selects live, sandbox, or explicit base_url" do
    live = Provider::TinkoffInvest::PortfolioClient.new(api_key: "tok", environment: :live)
    sandbox = Provider::TinkoffInvest::PortfolioClient.new(api_key: "tok", environment: :sandbox)
    custom = Provider::TinkoffInvest::PortfolioClient.new(api_key: "tok", environment: :sandbox, base_url: "https://proxy.example.test/rest/")

    assert_equal LIVE_API, live.base_url
    assert_equal SANDBOX_API, sandbox.base_url
    assert_equal "https://proxy.example.test/rest", custom.base_url
  end

  test "fetch_accounts posts to UsersService/GetAccounts" do
    stub_tinvest(LIVE_API, "UsersService", "GetAccounts", {
      accounts: [
        { id: "acct-1", type: "ACCOUNT_TYPE_TINKOFF", status: "ACCOUNT_STATUS_OPEN", name: "Brokerage" }
      ]
    })

    accounts = @client.fetch_accounts

    assert_equal 1, accounts.size
    assert_equal "acct-1", accounts.first["id"]
  end

  test "fetch_portfolio posts to OperationsService/GetPortfolio on sandbox" do
    sandbox_client = Provider::TinkoffInvest::PortfolioClient.new(api_key: "tok", environment: :sandbox)
    sandbox_client.stubs(:throttle_request)

    stub_tinvest(SANDBOX_API, "OperationsService", "GetPortfolio", {
      totalAmountPortfolio: { currency: "rub", units: "150000", nano: 0 },
      totalAmountCurrencies: { currency: "rub", units: "25000", nano: 0 },
      positions: []
    }, token: "tok")

    portfolio = sandbox_client.fetch_portfolio("sbx-1", currency: "RUB")

    assert_equal "150000", portfolio.dig("totalAmountPortfolio", "units")
  end

  test "fetch_operations pages with hasNext and nextCursor" do
    url = "#{LIVE_API}/#{NS}.OperationsService/GetOperationsByCursor"
    stub_request(:post, url)
      .with(body: hash_excluding("cursor"))
      .to_return(json_response(
        hasNext: true,
        nextCursor: "cursor-page-2",
        items: [ { id: "op-2", cursor: "cursor-top", type: "OPERATION_TYPE_BUY" } ]
      ))
    stub_request(:post, url)
      .with(body: hash_including("cursor" => "cursor-page-2"))
      .to_return(json_response(
        hasNext: false,
        nextCursor: "",
        items: [ { id: "op-1", cursor: "cursor-old", type: "OPERATION_TYPE_INPUT" } ]
      ))

    result = @client.fetch_operations("acct-1", from: "2024-01-01T00:00:00Z", to: "2025-01-01T00:00:00Z")

    assert_equal %w[op-2 op-1], result[:items].map { |i| i["id"] }
    assert_equal "cursor-top", result[:next_cursor]
  end

  test "fetch_operations detects repeated pagination cursors" do
    url = "#{LIVE_API}/#{NS}.OperationsService/GetOperationsByCursor"
    stub_request(:post, url).to_return(
      json_response(hasNext: true, nextCursor: "same-cursor", items: [ { id: "op-1" } ]),
      json_response(hasNext: true, nextCursor: "same-cursor", items: [ { id: "op-2" } ])
    )

    assert_raises(Provider::TinkoffInvest::PortfolioClient::Error) do
      @client.fetch_operations("acct-1")
    end
  end

  test "resolve_instrument enriches shares and bonds with BondBy metadata and caches results" do
    bond_req = stub_tinvest(LIVE_API, "InstrumentsService", "GetInstrumentBy", {
      instrument: {
        uid: "uid-ofz",
        figi: "BBG011FHFN80",
        ticker: "SU26238RMFS4",
        name: "OFZ 26238",
        instrumentType: "bond",
        classCode: "TQOB",
        exchange: "moex_mrng_evng_e_wknd_dlr",
        currency: "rub",
        countryOfRisk: "RU",
        brand: { logoName: "minfin.png" }
      }
    })
    bond_by_req = stub_tinvest(LIVE_API, "InstrumentsService", "BondBy", {
      instrument: {
        nominal: { currency: "rub", units: "1000", nano: 0 },
        initialNominal: { currency: "rub", units: "1000", nano: 0 },
        amortizationFlag: true
      }
    })

    meta = @client.resolve_instrument(instrument_uid: "uid-ofz", figi: "BBG011FHFN80")
    cached = @client.resolve_instrument(instrument_uid: "uid-ofz")

    assert_equal meta, cached
    assert_equal "SU26238RMFS4", meta.ticker
    assert_equal "MISX", meta.exchange_operating_mic
    assert_equal "RU", meta.country_code
    assert_equal "https://invest-brands.cdn-tinkoff.ru/minfinx160.png", meta.logo_url
    assert_equal BigDecimal("1000"), meta.nominal
    assert meta.amortization_flag
    assert_requested bond_req, times: 1
    assert_requested bond_by_req, times: 1
  end

  test "raises AuthenticationError immediately on 401/403 and redacts token" do
    req = stub_request(:post, "#{LIVE_API}/#{NS}.UsersService/GetAccounts")
      .to_return(status: 401, body: "Invalid Bearer secret-test-token")

    err = assert_raises(Provider::TinkoffInvest::PortfolioClient::AuthenticationError) do
      @client.fetch_accounts
    end

    assert_requested req, times: 1
    assert_not_includes err.message, "secret-test-token"
    assert_includes err.message, "[REDACTED]"
  end

  test "retries 429 and raises RateLimitError when exhausted" do
    req = stub_request(:post, "#{LIVE_API}/#{NS}.UsersService/GetAccounts")
      .to_return(status: 429, headers: { "Retry-After" => "0" }, body: "rate limited")

    assert_raises(Provider::TinkoffInvest::PortfolioClient::RateLimitError) do
      @client.fetch_accounts
    end

    assert_requested req, times: 4
  end

  test "raises PaginationTruncatedError when pagination stops at MAX_OPERATION_PAGES with hasNext true" do
    stub_request(:post, "#{LIVE_API}/#{NS}.OperationsService/GetOperationsByCursor")
      .to_return(
        json_response({ items: [ { id: "op-1" } ], hasNext: true, nextCursor: "cur-1" }),
        json_response({ items: [ { id: "op-2" } ], hasNext: true, nextCursor: "cur-2" })
      )

    original = Provider::TinkoffInvest::PortfolioClient::MAX_OPERATION_PAGES
    Provider::TinkoffInvest::PortfolioClient.send(:remove_const, :MAX_OPERATION_PAGES)
    Provider::TinkoffInvest::PortfolioClient.const_set(:MAX_OPERATION_PAGES, 2)

    assert_raises(Provider::TinkoffInvest::PortfolioClient::PaginationTruncatedError) do
      @client.fetch_operations("acct-1")
    end
  ensure
    Provider::TinkoffInvest::PortfolioClient.send(:remove_const, :MAX_OPERATION_PAGES)
    Provider::TinkoffInvest::PortfolioClient.const_set(:MAX_OPERATION_PAGES, original)
  end

  test "rejects non-loopback HTTP base_url and allows loopback HTTP" do
    assert_raises(Provider::TinkoffInvest::PortfolioClient::ConfigurationError) do
      Provider::TinkoffInvest::PortfolioClient.new(api_key: "tok", base_url: "http://evil.example/rest")
    end

    [ "http://127.0.0.1:8080/rest", "http://localhost:8080/rest", "http://[::1]:8080/rest" ].each do |loopback|
      client = Provider::TinkoffInvest::PortfolioClient.new(api_key: "tok", base_url: loopback)
      assert_equal loopback, client.base_url
    end
  end

  test "scopes Rails.cache instrument and bond keys by base_url" do
    live_client = Provider::TinkoffInvest::PortfolioClient.new(api_key: "secret-test-token", environment: :live)
    sandbox_client = Provider::TinkoffInvest::PortfolioClient.new(api_key: "secret-test-token", environment: :sandbox)
    live_client.stubs(:throttle_request)
    sandbox_client.stubs(:throttle_request)

    stub_tinvest(LIVE_API, "InstrumentsService", "GetInstrumentBy", {
      instrument: { uid: "uid-1", ticker: "SBER", name: "Sberbank Live", instrumentType: "share", currency: "rub" }
    })
    stub_tinvest(SANDBOX_API, "InstrumentsService", "GetInstrumentBy", {
      instrument: { uid: "uid-1", ticker: "SBER", name: "Sberbank Sandbox", instrumentType: "share", currency: "rub" }
    })

    live_meta = live_client.resolve_instrument(instrument_uid: "uid-1")
    sandbox_meta = sandbox_client.resolve_instrument(instrument_uid: "uid-1")

    assert_equal "Sberbank Live", live_meta.name
    assert_equal "Sberbank Sandbox", sandbox_meta.name
  end

  private

    def stub_tinvest(base, service, method, body, token: "secret-test-token")
      stub_request(:post, "#{base}/#{NS}.#{service}/#{method}")
        .with(headers: { "Authorization" => "Bearer #{token}" })
        .to_return(json_response(body))
    end

    def json_response(body)
      { status: 200, body: body.to_json, headers: { "Content-Type" => "application/json" } }
    end
end
