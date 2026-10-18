require "test_helper"

class Provider::SimplefinTest < ActiveSupport::TestCase
  setup do
    @provider = Provider::Simplefin.new
    @access_url = "https://example.com/simplefin/access"
    @provider.stubs(:resolve_addresses).returns([ "93.184.216.34" ])
  end

  test "retries on Net::ReadTimeout and succeeds on retry" do
    # First call raises timeout, second call succeeds
    mock_response = OpenStruct.new(code: 200, body: '{"accounts": []}')

    Provider::Simplefin.expects(:get)
      .times(2)
      .raises(Net::ReadTimeout.new("Connection timed out"))
      .then.returns(mock_response)

    # Stub sleep to avoid actual delays in tests
    @provider.stubs(:sleep)

    result = @provider.get_accounts(@access_url)
    assert_equal({ accounts: [] }, result)
  end

  test "retries on Net::OpenTimeout and succeeds on retry" do
    mock_response = OpenStruct.new(code: 200, body: '{"accounts": []}')

    Provider::Simplefin.expects(:get)
      .times(2)
      .raises(Net::OpenTimeout.new("Connection timed out"))
      .then.returns(mock_response)

    @provider.stubs(:sleep)

    result = @provider.get_accounts(@access_url)
    assert_equal({ accounts: [] }, result)
  end

  test "retries on SocketError and succeeds on retry" do
    mock_response = OpenStruct.new(code: 200, body: '{"accounts": []}')

    Provider::Simplefin.expects(:get)
      .times(2)
      .raises(SocketError.new("Failed to open TCP connection"))
      .then.returns(mock_response)

    @provider.stubs(:sleep)

    result = @provider.get_accounts(@access_url)
    assert_equal({ accounts: [] }, result)
  end

  test "raises SimplefinError after max retries exceeded" do
    Provider::Simplefin.expects(:get)
      .times(4) # Initial + 3 retries
      .raises(Net::ReadTimeout.new("Connection timed out"))

    @provider.stubs(:sleep)

    error = assert_raises(Provider::Simplefin::SimplefinError) do
      @provider.get_accounts(@access_url)
    end

    assert_equal :network_error, error.error_type
    assert_match(/Network error after 3 retries/, error.message)
  end

  test "does not retry on non-retryable errors" do
    Provider::Simplefin.expects(:get)
      .times(1)
      .raises(ArgumentError.new("Invalid argument"))

    error = assert_raises(Provider::Simplefin::SimplefinError) do
      @provider.get_accounts(@access_url)
    end

    assert_equal :request_failed, error.error_type
  end

  test "handles HTTP 429 rate limit response" do
    mock_response = OpenStruct.new(code: 429, body: "Rate limit exceeded")

    Provider::Simplefin.expects(:get).returns(mock_response)

    error = assert_raises(Provider::Simplefin::SimplefinError) do
      @provider.get_accounts(@access_url)
    end

    assert_equal :rate_limited, error.error_type
    assert_match(/rate limit exceeded/i, error.message)
  end

  test "handles HTTP 500 server error response" do
    mock_response = OpenStruct.new(code: 500, body: "Internal Server Error")

    Provider::Simplefin.expects(:get).returns(mock_response)

    error = assert_raises(Provider::Simplefin::SimplefinError) do
      @provider.get_accounts(@access_url)
    end

    assert_equal :server_error, error.error_type
  end

  test "get_accounts sends pending=1 when pending is enabled" do
    mock_response = OpenStruct.new(code: 200, body: '{"accounts": []}')

    Provider::Simplefin.expects(:get)
      .with { |url| url.include?("pending=1") }
      .returns(mock_response)

    @provider.get_accounts(@access_url, pending: true)
  end

  test "get_accounts omits the pending param when pending is disabled" do
    # The SimpleFIN protocol has no pending=0 — bridges presence-check the
    # param, so pending=0 behaves like pending=1. Disabling pending must omit
    # the param entirely.
    mock_response = OpenStruct.new(code: 200, body: '{"accounts": []}')

    Provider::Simplefin.expects(:get)
      .with { |url| !url.include?("pending") }
      .returns(mock_response)

    @provider.get_accounts(@access_url, pending: false)
  end

  test "get_accounts omits the pending param when pending is nil" do
    mock_response = OpenStruct.new(code: 200, body: '{"accounts": []}')

    Provider::Simplefin.expects(:get)
      .with { |url| !url.include?("pending") }
      .returns(mock_response)

    @provider.get_accounts(@access_url, pending: nil)
  end

  test "get_accounts requests protocol version 2" do
    mock_response = OpenStruct.new(code: 200, body: '{"accounts": []}')

    Provider::Simplefin.expects(:get)
      .with { |url| URI.parse(url).query.split("&").include?("version=2") }
      .returns(mock_response)

    @provider.get_accounts(@access_url)
  end

  test "claim_access_url retries on network errors" do
    setup_token = Base64.encode64("https://example.com/claim")
    mock_response = OpenStruct.new(code: 200, body: "https://example.com/access")

    Provider::Simplefin.expects(:post)
      .times(2)
      .raises(Net::ReadTimeout.new("Connection timed out"))
      .then.returns(mock_response)

    @provider.stubs(:sleep)

    result = @provider.claim_access_url(setup_token)
    assert_equal "https://example.com/access", result
  end

  test "exponential backoff delay increases with retries" do
    provider = Provider::Simplefin.new

    # Access private method for testing
    delay1 = provider.send(:calculate_retry_delay, 1)
    delay2 = provider.send(:calculate_retry_delay, 2)
    delay3 = provider.send(:calculate_retry_delay, 3)

    # Delays should increase (accounting for jitter)
    # Base delays: 2, 4, 8 seconds (with up to 25% jitter)
    assert delay1 >= 2 && delay1 <= 2.5, "First retry delay should be ~2s"
    assert delay2 >= 4 && delay2 <= 5, "Second retry delay should be ~4s"
    assert delay3 >= 8 && delay3 <= 10, "Third retry delay should be ~8s"
  end

  test "retry delay is capped at MAX_RETRY_DELAY" do
    provider = Provider::Simplefin.new

    # Test with a high retry count that would exceed max delay
    delay = provider.send(:calculate_retry_delay, 10)

    assert delay <= Provider::Simplefin::MAX_RETRY_DELAY,
      "Delay should be capped at MAX_RETRY_DELAY (#{Provider::Simplefin::MAX_RETRY_DELAY}s)"
  end

  test "claim_access_url rejects setup tokens pointing at link-local metadata addresses" do
    @provider.stubs(:resolve_addresses).with("169.254.169.254").returns([ "169.254.169.254" ])
    Provider::Simplefin.expects(:post).never

    error = assert_raises(Provider::Simplefin::SimplefinError) do
      @provider.claim_access_url(Base64.strict_encode64("http://169.254.169.254/latest/meta-data/"))
    end

    assert_equal :invalid_url, error.error_type
  end

  test "claim_access_url rejects hosts that resolve to a link-local address" do
    @provider.stubs(:resolve_addresses).with("metadata.example.test").returns([ "169.254.169.254" ])
    Provider::Simplefin.expects(:post).never

    error = assert_raises(Provider::Simplefin::SimplefinError) do
      @provider.claim_access_url(Base64.strict_encode64("https://metadata.example.test/claim"))
    end

    assert_equal :invalid_url, error.error_type
  end

  test "claim_access_url rejects the AWS IPv6 metadata address when self-hosted" do
    @provider.stubs(:resolve_addresses).with("metadata6.example.test").returns([ "fd00:ec2::254" ])
    Provider::Simplefin.expects(:post).never

    with_self_hosting do
      error = assert_raises(Provider::Simplefin::SimplefinError) do
        @provider.claim_access_url(Base64.strict_encode64("http://metadata6.example.test/latest"))
      end

      assert_equal :invalid_url, error.error_type
    end
  end

  test "claim_access_url rejects non-http schemes" do
    Provider::Simplefin.expects(:post).never

    error = assert_raises(Provider::Simplefin::SimplefinError) do
      @provider.claim_access_url(Base64.strict_encode64("file:///etc/passwd"))
    end

    assert_equal :invalid_url, error.error_type
  end

  test "claim_access_url allows private bridge addresses when self-hosted" do
    @provider.stubs(:resolve_addresses).with("bridge.lan").returns([ "192.168.1.20" ])
    Provider::Simplefin.expects(:post).returns(OpenStruct.new(code: 200, body: "http://user:pass@bridge.lan/simplefin"))

    with_self_hosting do
      assert_equal "http://user:pass@bridge.lan/simplefin",
        @provider.claim_access_url(Base64.strict_encode64("http://bridge.lan/simplefin/claim/abc"))
    end
  end

  test "claim_access_url rejects private and loopback addresses on managed instances" do
    Rails.configuration.stubs(:app_mode).returns("managed".inquiry)
    Provider::Simplefin.expects(:post).never

    {
      "bridge.lan" => "192.168.1.20", "localhost" => "127.0.0.1", "v6.lan" => "fd00::1",
      "cgnat.example.test" => "100.64.0.1", "bench.example.test" => "198.18.0.1"
    }.each do |host, address|
      @provider.stubs(:resolve_addresses).with(host).returns([ address ])

      error = assert_raises(Provider::Simplefin::SimplefinError, "#{host} should be rejected") do
        @provider.claim_access_url(Base64.strict_encode64("https://#{host}/claim"))
      end

      assert_equal :invalid_url, error.error_type
    end
  end

  test "claim_access_url requires https on managed instances" do
    Rails.configuration.stubs(:app_mode).returns("managed".inquiry)
    Provider::Simplefin.expects(:post).never

    error = assert_raises(Provider::Simplefin::SimplefinError) do
      @provider.claim_access_url(Base64.strict_encode64("http://bridge.simplefin.org/claim"))
    end

    assert_equal :invalid_url, error.error_type
  end

  test "claim_access_url rejects an access URL pointing at a disallowed address" do
    @provider.stubs(:resolve_addresses).with("169.254.169.254").returns([ "169.254.169.254" ])
    Provider::Simplefin.expects(:post).returns(OpenStruct.new(code: 200, body: "http://169.254.169.254/latest"))

    error = assert_raises(Provider::Simplefin::SimplefinError) do
      @provider.claim_access_url(Base64.strict_encode64("https://example.com/claim"))
    end

    assert_equal :invalid_url, error.error_type
  end

  test "claim_access_url keeps the claimed access URL without resolving its host" do
    Provider::Simplefin.expects(:post).returns(OpenStruct.new(code: 200, body: "https://user:pass@flaky.example.test/simplefin"))
    @provider.expects(:resolve_addresses).with("flaky.example.test").never

    assert_equal "https://user:pass@flaky.example.test/simplefin",
      @provider.claim_access_url(Base64.strict_encode64("https://example.com/claim"))
  end

  test "claim_access_url does not follow redirects" do
    Provider::Simplefin.expects(:post).with("https://example.com/claim", has_entry(follow_redirects: false))
      .returns(OpenStruct.new(code: 200, body: "https://example.com/access"))

    @provider.claim_access_url(Base64.strict_encode64("https://example.com/claim"))
  end

  test "get_accounts does not echo the response body in error messages" do
    Provider::Simplefin.expects(:get).returns(OpenStruct.new(code: 418, message: "I'm a teapot", body: "internal-secret"))

    error = assert_raises(Provider::Simplefin::SimplefinError) { @provider.get_accounts(@access_url) }

    assert_not_includes error.message, "internal-secret"
  end

  test "get_accounts rejects a stored access URL pointing at a disallowed address" do
    @provider.stubs(:resolve_addresses).with("169.254.169.254").returns([ "169.254.169.254" ])
    Provider::Simplefin.expects(:get).never

    error = assert_raises(Provider::Simplefin::SimplefinError) do
      @provider.get_accounts("http://user:pass@169.254.169.254/simplefin")
    end

    assert_equal :invalid_url, error.error_type
  end

  test "get_accounts does not follow redirects" do
    Provider::Simplefin.expects(:get).with("#{@access_url}/accounts?version=2", has_entry(follow_redirects: false))
      .returns(OpenStruct.new(code: 200, body: '{"accounts": []}'))

    @provider.get_accounts(@access_url)
  end

  test "get_info rejects a base URL pointing at a disallowed address" do
    @provider.stubs(:resolve_addresses).with("169.254.169.254").returns([ "169.254.169.254" ])
    Provider::Simplefin.expects(:get).never

    error = assert_raises(Provider::Simplefin::SimplefinError) do
      @provider.get_info("http://169.254.169.254/simplefin")
    end

    assert_equal :invalid_url, error.error_type
  end

  test "get_info does not follow redirects" do
    Provider::Simplefin.expects(:get).with("https://example.com/simplefin/info", has_entry(follow_redirects: false))
      .returns(OpenStruct.new(code: 200, body: "1.0\n"))

    assert_equal [ "1.0" ], @provider.get_info("https://example.com/simplefin")
  end

  test "an unresolvable host raises a network error, not an invalid url" do
    @provider.stubs(:sleep)
    @provider.stubs(:resolve_addresses).with("flaky.example.test").raises(SocketError, "getaddrinfo: Name or service not known")
    Provider::Simplefin.expects(:get).never

    error = assert_raises(Provider::Simplefin::SimplefinError) do
      @provider.get_accounts("https://user:pass@flaky.example.test/simplefin")
    end

    assert_equal :network_error, error.error_type
  end

  test "a transient DNS failure during sync is retried" do
    @provider.stubs(:sleep)
    @provider.stubs(:resolve_addresses).with("example.com")
      .raises(SocketError, "getaddrinfo: Temporary failure in name resolution").then.returns([ "93.184.216.34" ])
    Provider::Simplefin.expects(:get).once.returns(OpenStruct.new(code: 200, body: '{"accounts": []}'))

    assert_equal({ accounts: [] }, @provider.get_accounts(@access_url))
  end

  test "rejects IPv6 addresses that carry a blocked IPv4 address" do
    Provider::Simplefin.expects(:get).never

    with_self_hosting do
      [ "::ffff:169.254.169.254", "64:ff9b::a9fe:a9fe", "::ffff:0:a9fe:a9fe", "2002:a9fe:a9fe::1", "::a9fe:a9fe" ].each do |address|
        @provider.stubs(:resolve_addresses).with("wrapped.example.test").returns([ address ])

        error = assert_raises(Provider::Simplefin::SimplefinError, "#{address} should be rejected") do
          @provider.get_accounts("https://wrapped.example.test/simplefin")
        end

        assert_equal :invalid_url, error.error_type
      end
    end
  end

  test "rejects multicast and reserved addresses when self-hosted" do
    Provider::Simplefin.expects(:get).never

    with_self_hosting do
      [ "224.0.0.1", "255.255.255.255", "ff02::1" ].each do |address|
        @provider.stubs(:resolve_addresses).with("odd.example.test").returns([ address ])

        error = assert_raises(Provider::Simplefin::SimplefinError, "#{address} should be rejected") do
          @provider.get_accounts("https://odd.example.test/simplefin")
        end

        assert_equal :invalid_url, error.error_type
      end
    end
  end

  test "connects to the checked address, preferring IPv4" do
    @provider.stubs(:resolve_addresses).with("example.com").returns([ "2606:2800:220:1::1", "93.184.216.34" ])
    Provider::Simplefin.expects(:get).with(
      "#{@access_url}/accounts?version=2",
      has_entries(
        connection_adapter: Provider::Simplefin::PinnedConnectionAdapter,
        connection_adapter_options: { ipaddr: "93.184.216.34" }
      )
    ).returns(OpenStruct.new(code: 200, body: '{"accounts": []}'))

    @provider.get_accounts(@access_url)
  end

  test "the pinned connection adapter connects to the given address" do
    http = Provider::Simplefin::PinnedConnectionAdapter.new(
      URI("https://example.com/simplefin"),
      connection_adapter_options: { ipaddr: "93.184.216.34" }
    ).connection

    assert_equal "93.184.216.34", http.ipaddr
    assert_equal "example.com", http.address
  end

  test "rejects the Alibaba Cloud metadata address when self-hosted" do
    @provider.stubs(:resolve_addresses).with("meta.example.test").returns([ "100.100.100.200" ])
    Provider::Simplefin.expects(:get).never

    with_self_hosting do
      error = assert_raises(Provider::Simplefin::SimplefinError) do
        @provider.get_accounts("https://meta.example.test/simplefin")
      end

      assert_equal :invalid_url, error.error_type
    end
  end

  test "connects to an IPv4-mapped address as plain IPv4" do
    @provider.stubs(:resolve_addresses).with("example.com").returns([ "::ffff:93.184.216.34" ])
    Provider::Simplefin.expects(:get).with(
      "#{@access_url}/accounts?version=2", has_entry(connection_adapter_options: { ipaddr: "93.184.216.34" })
    ).returns(OpenStruct.new(code: 200, body: '{"accounts": []}'))

    @provider.get_accounts(@access_url)
  end

  test "a retry connects to the next checked address" do
    @provider.stubs(:sleep)
    @provider.stubs(:resolve_addresses).with("example.com").returns([ "93.184.216.34", "93.184.216.35" ])
    sequence = sequence("addresses")
    Provider::Simplefin.expects(:get).with(anything, has_entry(connection_adapter_options: { ipaddr: "93.184.216.34" }))
      .in_sequence(sequence).raises(Errno::ECONNREFUSED)
    Provider::Simplefin.expects(:get).with(anything, has_entry(connection_adapter_options: { ipaddr: "93.184.216.35" }))
      .in_sequence(sequence).returns(OpenStruct.new(code: 200, body: '{"accounts": []}'))

    assert_equal({ accounts: [] }, @provider.get_accounts(@access_url))
  end

  test "plain http requests bypass a proxy so the pinned address is used" do
    @provider.stubs(:resolve_addresses).with("bridge.lan").returns([ "192.168.1.20" ])
    Provider::Simplefin.expects(:get).with(anything, has_entry(http_proxyaddr: nil))
      .returns(OpenStruct.new(code: 200, body: '{"accounts": []}'))

    with_self_hosting { @provider.get_accounts("http://user:pass@bridge.lan/simplefin") }
  end

  test "https requests keep the configured proxy" do
    Provider::Simplefin.expects(:get).with(anything, Not(has_key(:http_proxyaddr)))
      .returns(OpenStruct.new(code: 200, body: '{"accounts": []}'))

    @provider.get_accounts(@access_url)
  end

  test "validate_setup_token! rejects disallowed claim URLs without claiming" do
    @provider.stubs(:resolve_addresses).with("169.254.169.254").returns([ "169.254.169.254" ])
    Provider::Simplefin.expects(:post).never

    error = assert_raises(Provider::Simplefin::SimplefinError) do
      @provider.validate_setup_token!(Base64.strict_encode64("http://169.254.169.254/claim"))
    end

    assert_equal :invalid_url, error.error_type
  end

  test "validate_setup_token! reports an unresolvable host as a network error" do
    @provider.stubs(:resolve_addresses).with("flaky.example.test").raises(SocketError, "getaddrinfo failed")

    error = assert_raises(Provider::Simplefin::SimplefinError) do
      @provider.validate_setup_token!(Base64.strict_encode64("https://flaky.example.test/claim"))
    end

    assert_equal :network_error, error.error_type
  end
end
