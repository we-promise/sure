require "test_helper"

# The HTTP boundary had no coverage: test/models/provider/open_banking_io_test.rb stubs
# Client wholesale, so nothing exercised header construction, status mapping, the SSRF
# properties the comments claim, or (once added) the retry layer.
class Provider::OpenBankingIo::ClientTest < ActiveSupport::TestCase
  BASE = "https://open-banking.io".freeze

  setup do
    key = OpenSSL::PKey::EC.generate("prime256v1")
    @private_key_b64 = Base64.strict_encode64(key.private_to_der)
    # Retries are real sleeps otherwise; every backoff test would add seconds.
    Provider::OpenBankingIo::Client.any_instance.stubs(:sleep)
  end

  def client(**overrides)
    Provider::OpenBankingIo::Client.new(
      api_base_url: BASE,
      api_key: "test-api-key",
      private_key_pkcs8: @private_key_b64,
      **overrides
    )
  end

  def stub_accounts(status: 200, body: "[]", headers: {})
    stub_request(:get, "#{BASE}/api/accounts").to_return(status: status, body: body, headers: headers)
  end

  # === REQUEST CONSTRUCTION ===

  test "sends the api key, accept and pinned user agent on every request" do
    stub = stub_request(:get, "#{BASE}/api/accounts")
      .with(headers: {
        "X-Api-Key" => "test-api-key",
        "Accept" => "application/json",
        "User-Agent" => Provider::OpenBankingIo::Client::USER_AGENT
      })
      .to_return(status: 200, body: "[]")

    client.get_accounts

    assert_requested(stub)
  end

  test "normalises a base url with trailing slashes" do
    stub = stub_accounts
    Provider::OpenBankingIo::Client.new(
      api_base_url: "#{BASE}///", api_key: "k", private_key_pkcs8: @private_key_b64
    ).get_accounts

    assert_requested(stub)
  end

  test "builds transaction query params only for the values given" do
    stub = stub_request(:get, "#{BASE}/api/accounts/acc-1/transactions")
      .with(query: { "from" => "2026-01-01", "limit" => "500", "offset" => "0" })
      .to_return(status: 200, body: { items: [], total: 0 }.to_json)

    client.get_transactions("acc-1", from: "2026-01-01", to: nil, limit: 500, offset: 0)

    assert_requested(stub)
  end

  # === SSRF PROPERTIES ===
  # The client's comments assert these; nothing proved them until now.

  test "does not follow a redirect to another host" do
    stub_request(:get, "#{BASE}/api/accounts")
      .to_return(status: 302, headers: { "Location" => "https://evil.example.com/api/accounts" })
    evil = stub_request(:get, "https://evil.example.com/api/accounts")

    assert_raises(Provider::OpenBankingIo::HTTPError) { client.get_accounts }
    assert_not_requested(evil)
  end

  test "a relative path cannot escape the pinned host" do
    c = client
    assert_equal "open-banking.io", c.send(:resolve, "../../evil").host
    assert_equal "open-banking.io", c.send(:resolve, "api/accounts").host
    # A protocol-relative reference is the classic escape; URI#+ would honour it, so the
    # leading-slash strip in #resolve is load-bearing.
    assert_equal "open-banking.io", c.send(:resolve, "//evil.example.com/x").host
  end

  test "refuses to issue a plaintext http request" do
    c = client
    uri = URI.parse("http://open-banking.io/api/accounts")
    assert_raises(ArgumentError) { c.send(:send_request, uri, Net::HTTP::Get.new(uri)) }
  end

  # === STATUS MAPPING ===

  test "raises HTTPError carrying the status and body for a non-2xx" do
    stub_accounts(status: 418, body: "teapot")

    error = assert_raises(Provider::OpenBankingIo::HTTPError) { client.get_accounts }
    assert_equal 418, error.status
    assert_equal "teapot", error.body
  end

  test "maps every status the service can emit to a distinct error type" do
    {
      401 => :unauthorized,
      402 => :payment_required,
      403 => :access_forbidden,
      404 => :not_found,
      409 => :requires_reconnect,
      429 => :rate_limited,
      502 => :bank_error,
      503 => :server_error,
      500 => :server_error,
      400 => :fetch_failed
    }.each do |status, expected|
      provider = Provider::OpenBankingIo.new(
        api_base_url: BASE, api_key: "k", private_key: @private_key_b64
      )
      assert_equal expected, provider.send(:error_type_for_status, status), "HTTP #{status}"
    end
  end

  test "surfaces the problem details reason, bank error code and trace id" do
    body = { reason: "reconnect_needed", bankErrorCode: "EB-401", traceId: "abc123", detail: "ignored" }.to_json
    stub_accounts(status: 409, body: body)

    provider = Provider::OpenBankingIo.new(api_base_url: BASE, api_key: "k", private_key: @private_key_b64)
    error = assert_raises(Provider::OpenBankingIo::Error) { provider.get_accounts }

    assert_equal :requires_reconnect, error.error_type
    assert_match(/reconnect_needed/, error.message)
    assert_match(/EB-401/, error.message)
    assert_match(/abc123/, error.message, "traceId is the only handle into the server's sync_attempt_log")
  end

  test "returns nil rather than raising for an empty response body" do
    stub_request(:post, "#{BASE}/api/sync").to_return(status: 200, body: "")
    assert_nil client.send(:post_json, "api/sync", {})
  end

  # === RETRY / BACKOFF ===

  test "retries a 429 and succeeds on a later attempt" do
    stub_request(:get, "#{BASE}/api/accounts")
      .to_return({ status: 429, body: "" }, { status: 200, body: "[]" })

    assert_equal [], client.get_accounts
  end

  test "retries a 503" do
    stub_request(:get, "#{BASE}/api/accounts").to_return({ status: 503, body: "" }, { status: 200, body: "[]" })

    assert_equal [], client.get_accounts
  end

  test "never retries a 502" do
    # The bank answered, and answered no. Retrying just asks it again.
    stub = stub_accounts(status: 502)

    assert_raises(Provider::OpenBankingIo::HTTPError) { client.get_accounts }
    assert_requested(stub, times: 1)
  end

  test "does not retry a 401" do
    stub = stub_accounts(status: 401)
    assert_raises(Provider::OpenBankingIo::HTTPError) { client.get_accounts }
    assert_requested(stub, times: 1)
  end

  test "gives up after MAX_RETRIES attempts" do
    stub = stub_accounts(status: 429)
    assert_raises(Provider::OpenBankingIo::HTTPError) { client.get_accounts }

    assert_requested(stub, times: Provider::OpenBankingIo::Client::MAX_RETRIES + 1)
  end

  test "retries a network error" do
    stub_request(:get, "#{BASE}/api/accounts")
      .to_raise(Errno::ECONNRESET).then
      .to_return(status: 200, body: "[]")

    assert_equal [], client.get_accounts
  end

  # The sync endpoints advertise Retry-After: 21600 when Enable Banking throttles the whole
  # application. Sleeping that inside a Sidekiq worker pins it for six hours.
  test "refuses to sleep on a Retry-After beyond the honoured cap" do
    stub = stub_accounts(status: 429, headers: { "Retry-After" => "21600" })

    assert_raises(Provider::OpenBankingIo::HTTPError) { client.get_accounts }
    assert_requested(stub, times: 1)
  end

  test "honours a short Retry-After" do
    stub_request(:get, "#{BASE}/api/accounts")
      .to_return({ status: 429, headers: { "Retry-After" => "2" }, body: "" }, { status: 200, body: "[]" })

    assert_equal [], client.get_accounts
  end

  test "retry delay is bounded by MAX_RETRY_DELAY" do
    c = client
    error = Provider::OpenBankingIo::HTTPError.new(429, nil)

    10.times do |attempt|
      delay = c.send(:retry_delay, error, attempt + 1)
      assert_operator delay, :<=, Provider::OpenBankingIo::Client::MAX_RETRY_DELAY
    end
  end

  # === PAGINATION ===

  test "raises rather than silently truncating at the page cap" do
    full_page = { items: Array.new(500) { |i| { id: "t#{i}", enc: nil } }, total: 10_000_000 }.to_json
    stub_request(:get, %r{#{BASE}/api/accounts/acc-1/transactions}).to_return(status: 200, body: full_page)

    provider = Provider::OpenBankingIo.new(api_base_url: BASE, api_key: "k", private_key: @private_key_b64)
    error = assert_raises(Provider::OpenBankingIo::Error) do
      provider.get_account_transactions(account_id: "acc-1")
    end

    assert_equal :pagination_truncated, error.error_type
  end

  test "stops once the reported total is reached" do
    stub = stub_request(:get, %r{#{BASE}/api/accounts/acc-1/transactions})
      .to_return(status: 200, body: { items: Array.new(500) { |i| { id: "t#{i}" } }, total: 500 }.to_json)

    provider = Provider::OpenBankingIo.new(api_base_url: BASE, api_key: "k", private_key: @private_key_b64)
    result = provider.get_account_transactions(account_id: "acc-1")

    assert_equal 500, result.size
    assert_requested(stub, times: 1)
  end

  test "PAGE_LIMIT never exceeds the server page cap" do
    # A larger value is clamped server-side, which makes the short-page terminator fire on
    # page one and silently import a single page of an N-page statement.
    assert_operator Provider::OpenBankingIo::PAGE_LIMIT, :<=, 500
  end
end
