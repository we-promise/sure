require "test_helper"

class Provider::WiseTest < ActiveSupport::TestCase
  setup do
    @provider = Provider::Wise.new("test_token", base_url: "https://api.wise.com")
  end

  # Wise retired the V1 sandbox host, api.sandbox.transferwise.tech, on 30 June
  # 2026. The provider panel tells testers which host to set as WISE_BASE_URL.
  test "points the sandbox at Wise's current host, as the panel says in every locale" do
    assert_equal "https://api.wise-sandbox.com", Provider::Wise::SANDBOX_BASE_URL

    I18n.available_locales.each do |locale|
      assert_includes I18n.t("wise_items.provider_panel.sandbox_note_html", locale: locale), Provider::Wise::SANDBOX_BASE_URL,
                      "sandbox note in #{locale}"
    end
  end

  test "chunks balance statement requests into windows under the 469-day limit" do
    start_date = Date.new(2015, 4, 12)
    end_date = Date.new(2018, 4, 30)

    expected_windows = []
    window_start = start_date
    while window_start <= end_date
      window_end = [ window_start + (Provider::Wise::MAX_STATEMENT_DAYS - 1), end_date ].min
      expected_windows << {
        interval_start: window_start.beginning_of_day,
        interval_end: window_end.end_of_day
      }
      window_start = window_end + 1.day
    end
    assert_operator expected_windows.size, :>, 1

    expected_windows.each do |window|
      @provider.expects(:get_balance_statement)
        .with("111", "222", currency: "EUR",
              interval_start: window[:interval_start],
              interval_end: window[:interval_end])
        .returns({ "transactions" => [] })
        .once
    end

    result = @provider.get_balance_statements("111", "222", currency: "EUR", start_date: start_date, end_date: end_date)

    assert_equal [], result
  end

  test "uses a single request when the range fits within the limit" do
    @provider.stubs(:get_balance_statement)
      .with("111", "222", currency: "EUR",
            interval_start: Date.new(2018, 1, 1).beginning_of_day,
            interval_end: Date.new(2018, 4, 30).end_of_day)
      .returns({ "transactions" => [] })

    result = @provider.get_balance_statements(
      "111",
      "222",
      currency: "EUR",
      start_date: Date.new(2018, 1, 1),
      end_date: Date.new(2018, 4, 30)
    )

    assert_equal [], result
  end

  test "signs the SCA challenge and retries once when a private key is configured" do
    key = OpenSSL::PKey::RSA.new(2048)
    provider = Provider::Wise.new("test_token", base_url: "https://api.wise.com", sca_private_key: key.to_pem)

    challenge = "one-time-token-abc"
    expected_signature = Base64.strict_encode64(key.sign(OpenSSL::Digest::SHA256.new, challenge))

    Provider::Wise.expects(:get)
      .with { |_url, options| options[:headers]["x-2fa-approval"].nil? }
      .returns(fake_response(code: 403, headers: { "x-2fa-approval" => challenge }))
    Provider::Wise.expects(:get)
      .with { |_url, options|
        options[:headers]["x-2fa-approval"] == challenge &&
          options[:headers]["X-Signature"] == expected_signature
      }
      .returns(fake_response(code: 200, body: '{"ok":true}'))

    result = provider.send(:get, "/v1/profiles/1/balance-statements/2/statement.json")

    assert_equal({ "ok" => true }, result)
  end

  test "does not retry a 403 when no SCA private key is configured" do
    Provider::Wise.expects(:get).once.returns(fake_response(code: 403, headers: { "x-2fa-approval" => "abc" }))

    error = assert_raises(Provider::Wise::WiseError) { @provider.send(:get, "/v1/me") }
    assert_equal :access_forbidden, error.error_type
  end

  test "does not loop forever if the signed retry still fails" do
    key = OpenSSL::PKey::RSA.new(2048)
    provider = Provider::Wise.new("test_token", base_url: "https://api.wise.com", sca_private_key: key.to_pem)

    Provider::Wise.expects(:get).twice.returns(fake_response(code: 403, headers: { "x-2fa-approval" => "abc" }))

    error = assert_raises(Provider::Wise::WiseError) { provider.send(:get, "/v1/me") }
    assert_equal :access_forbidden, error.error_type
  end

  test "retries a rate-limited window without restarting earlier windows" do
    error = Provider::Wise::WiseError.new("rate limited", :rate_limited)
    # The retry helper is shared with the importer and sleeps at class level.
    Provider::Wise.stubs(:sleep)
    @provider.stubs(:get_balance_statement)
      .raises(error).then
      .returns({ "transactions" => [] }).then
      .returns({ "transactions" => [] })

    result = @provider.get_balance_statements(
      "111",
      "222",
      currency: "EUR",
      start_date: Date.new(2018, 1, 1),
      end_date: Date.new(2018, 4, 30)
    )

    assert_equal [], result
  end

  # Wise ignores `cursor`: only `nextCursor` reaches the next page.
  test "pages activities with nextCursor and bounds them with since" do
    sent = nil
    Provider::Wise.expects(:get)
      .with { |url, options| sent = [ url, options[:query] ] }
      .returns(fake_response(code: 200, body: '{"activities":[],"cursor":null}'))

    @provider.get_activities(123, cursor: "abc", since: Time.utc(2025, 7, 9, 16, 45))

    assert_equal "https://api.wise.com/v1/profiles/123/activities", sent.first
    assert_equal({ size: 100, nextCursor: "abc", since: "2025-07-09T16:45:00Z" }, sent.last)
  end

  test "filters transfers by their UTC creation date" do
    sent = nil
    Provider::Wise.expects(:get)
      .with { |_url, options| sent = options[:query] }
      .returns(fake_response(code: 200, body: "[]"))

    @provider.get_transfers(123, limit: 100, offset: 200, created_date_start: Time.utc(2025, 10, 7, 23, 59))

    assert_equal({ profile: 123, limit: 100, offset: 200, createdDateStart: "2025-10-07" }, sent)
  end

  test "reads the multi-currency account from the v4 endpoint" do
    Provider::Wise.expects(:get)
      .with { |url, _options| url == "https://api.wise.com/v4/profiles/123/multi-currency-account" }
      .returns(fake_response(code: 200, body: '{"recipientId":12345678}'))

    assert_equal({ "recipientId" => 12345678 }, @provider.get_multi_currency_account(123))
  end

  test "a rate-limited response carries Wise's Retry-After" do
    Provider::Wise.expects(:get).returns(fake_response(code: 429, headers: { "Retry-After" => "30" }))

    error = assert_raises(Provider::Wise::WiseError) { @provider.get_activities(123) }

    assert_equal :rate_limited, error.error_type
    assert_equal 30, error.retry_after
  end

  test "rate-limit retries wait for Retry-After when it is longer than the backoff, capped" do
    Provider::Wise.stubs(:rand).returns(0.5)
    waits = sequence("waits")
    Provider::Wise.expects(:sleep).with(30.5).in_sequence(waits)
    Provider::Wise.expects(:sleep).with(4.5).in_sequence(waits)
    Provider::Wise.expects(:sleep).with(Provider::Wise::RETRY_MAX_WAIT).in_sequence(waits)
    errors = [ 30, nil, 60 ].map { |seconds| Provider::Wise::WiseError.new("rate limited", :rate_limited, retry_after: seconds) }
    attempts = 0

    result = Provider::Wise.with_retries do
      attempts += 1
      raise errors[attempts - 1] if attempts <= errors.size

      :fetched
    end

    assert_equal :fetched, result
  end

  # Asking again before Wise's Retry-After is over would be refused too.
  test "does not wait out a Retry-After beyond the cap" do
    Provider::Wise.expects(:sleep).never
    attempts = 0

    error = assert_raises(Provider::Wise::WiseError) do
      Provider::Wise.with_retries do
        attempts += 1
        raise Provider::Wise::WiseError.new("rate limited", :rate_limited, retry_after: 300)
      end
    end

    assert_equal [ :rate_limited, 1 ], [ error.error_type, attempts ]
  end

  test "gives up after three rate-limited retries" do
    Provider::Wise.stubs(:sleep)
    attempts = 0

    assert_raises(Provider::Wise::WiseError) do
      Provider::Wise.with_retries do
        attempts += 1
        raise Provider::Wise::WiseError.new("rate limited", :rate_limited)
      end
    end
    assert_equal 4, attempts
  end

  # One 5xx answer or timeout on page 150 of a long history used to drop
  # the whole source for the sync.
  test "retries a server error and a request that failed on the way, but not an answer that will not change" do
    Provider::Wise.stubs(:sleep)
    outcomes = { server_error: :fetched, request_failed: :fetched, fetch_failed: :raised, access_forbidden: :raised, not_found: :raised }

    outcomes.each do |error_type, expected|
      attempts = 0
      outcome = begin
        Provider::Wise.with_retries do
          attempts += 1
          raise Provider::Wise::WiseError.new("failed", error_type) if attempts == 1

          :fetched
        end
      rescue Provider::Wise::WiseError
        :raised
      end
      assert_equal expected, outcome, error_type
    end
  end

  test "tells a server error from another unexpected response" do
    { 502 => :server_error, 503 => :server_error, 422 => :fetch_failed }.each do |code, error_type|
      Provider::Wise.expects(:get).returns(fake_response(code: code, body: "{}"))

      error = assert_raises(Provider::Wise::WiseError) { @provider.get_balances(123) }

      assert_equal error_type, error.error_type, code
    end
  end

  test "tells a 403 that carried an SCA challenge from one that did not" do
    Provider::Wise.expects(:get).returns(fake_response(code: 403, headers: { "x-2fa-approval" => "abc" }))
    challenged = assert_raises(Provider::Wise::WiseError) { @provider.send(:get, "/v1/me") }

    Provider::Wise.expects(:get).returns(fake_response(code: 403))
    refused = assert_raises(Provider::Wise::WiseError) { @provider.send(:get, "/v1/me") }

    assert_equal [ :access_forbidden, :access_forbidden ], [ challenged.error_type, refused.error_type ]
    assert challenged.sca_challenged?
    assert_not refused.sca_challenged?
  end

  private

    FakeResponse = Struct.new(:code, :body, :headers)

    def fake_response(code:, body: "{}", headers: {})
      FakeResponse.new(code, body, headers)
    end
end
