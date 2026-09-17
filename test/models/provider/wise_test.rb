require "test_helper"

class Provider::WiseTest < ActiveSupport::TestCase
  setup do
    @provider = Provider::Wise.new("test_token", base_url: "https://api.wise.com")
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
    @provider.stubs(:sleep)
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

  private

    FakeResponse = Struct.new(:code, :body, :headers)

    def fake_response(code:, body: "{}", headers: {})
      FakeResponse.new(code, body, headers)
    end
end
