require "test_helper"

class Provider::SimplefinTest < ActiveSupport::TestCase
  setup do
    @provider = Provider::Simplefin.new
    @access_url = "https://example.com/simplefin/access"
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
end
