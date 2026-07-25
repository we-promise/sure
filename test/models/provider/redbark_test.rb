require "test_helper"

class Provider::RedbarkTest < ActiveSupport::TestCase
  test "initializes with api key" do
    provider = Provider::Redbark.new(api_key: "rbk_live_test")
    assert_equal "rbk_live_test", provider.api_key
  end

  test "raises configuration error when api key blank" do
    assert_raises(Provider::Redbark::ConfigurationError) do
      Provider::Redbark.new(api_key: "")
    end
  end

  test "error includes error_type" do
    error = Provider::Redbark::Error.new("Test error", :unauthorized)
    assert_equal "Test error", error.message
    assert_equal :unauthorized, error.error_type
  end

  test "error defaults error_type to unknown" do
    error = Provider::Redbark::Error.new("Test error")
    assert_equal :unknown, error.error_type
  end

  test "rate limit and server errors are typed for retry handling" do
    assert Provider::Redbark::RateLimitError.new("limited", :rate_limited).is_a?(Provider::Redbark::Error)
    assert Provider::Redbark::ServerError.new("boom", :server_error).is_a?(Provider::Redbark::Error)
  end

  test "get_transactions splits the window when the server truncates" do
    provider = Provider::Redbark.new(api_key: "rbk_live_test")

    stub_request(:get, "https://api.redbark.com/v1/transactions")
      .with(query: hash_including("from" => "2026-01-01", "to" => "2026-01-31"))
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json", "X-Redbark-Truncated" => "true" },
        body: { data: [ { id: "t1" } ], pagination: { hasMore: true } }.to_json
      )
    stub_request(:get, "https://api.redbark.com/v1/transactions")
      .with(query: hash_including("from" => "2026-01-01", "to" => "2026-01-16"))
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: { data: [ { id: "t1" }, { id: "t2" } ], pagination: { hasMore: false } }.to_json
      )
    stub_request(:get, "https://api.redbark.com/v1/transactions")
      .with(query: hash_including("from" => "2026-01-17", "to" => "2026-01-31"))
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: { data: [ { id: "t3" } ], pagination: { hasMore: false } }.to_json
      )

    results = provider.get_transactions(
      connection_id: "conn_1",
      account_id: "acc_1",
      start_date: Date.new(2026, 1, 1),
      end_date: Date.new(2026, 1, 31)
    )

    assert_equal %w[t1 t2 t3], results.map { |t| t[:id] }
  end

  test "get_transactions raises when a truncated window cannot be narrowed" do
    provider = Provider::Redbark.new(api_key: "rbk_live_test")

    stub_request(:get, "https://api.redbark.com/v1/transactions")
      .with(query: hash_including("connectionId" => "conn_1"))
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json", "X-Redbark-Truncated" => "true" },
        body: { data: [ { id: "t1" } ], pagination: { hasMore: true } }.to_json
      )

    error = assert_raises(Provider::Redbark::Error) do
      provider.get_transactions(
        connection_id: "conn_1",
        account_id: "acc_1",
        start_date: Date.new(2026, 1, 5),
        end_date: Date.new(2026, 1, 5)
      )
    end
    assert_equal :truncated, error.error_type
  end
end
