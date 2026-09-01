# frozen_string_literal: true

require "test_helper"

class Provider::CoinspotTest < ActiveSupport::TestCase
  setup do
    @provider = Provider::Coinspot.new(api_key: "test_key", api_secret: "test_secret", nonce_generator: -> { 1616492376594 })
  end

  test "read only requests send compact json body signed with hmac sha512" do
    expected_body = JSON.generate({ "nonce" => 1616492376594 })
    expected_signature = OpenSSL::HMAC.hexdigest("sha512", "test_secret", expected_body)
    response = mock_httparty_response(200, { "status" => "ok", "balances" => [] })

    Provider::Coinspot.expects(:post)
      .with(
        "/api/v2/ro/my/balances",
        has_entries(
          body: expected_body,
          headers: has_entries(
            "Content-Type" => "application/json",
            "key" => "test_key",
            "sign" => expected_signature
          )
        )
      )
      .returns(response)

    assert_equal({ "status" => "ok", "balances" => [] }, @provider.get_balances)
  end

  test "history requests include date params in signed body" do
    response = mock_httparty_response(200, { "status" => "ok", "buyorders" => [] })

    Provider::Coinspot.expects(:post)
      .with(
        "/api/v2/ro/my/orders/completed",
        has_entries(body: JSON.generate({
          "nonce" => 1616492376594,
          "startdate" => "2026-01-01",
          "enddate" => "2026-01-31"
        }))
      )
      .returns(response)

    @provider.get_order_history(startdate: Date.new(2026, 1, 1), enddate: Date.new(2026, 1, 31))
  end

  test "handle response raises api error for non 2xx" do
    response = mock_httparty_response(500, { "status" => "error", "message" => "unavailable" })

    assert_raises(Provider::Coinspot::ApiError) do
      @provider.send(:handle_response, response)
    end
  end

  test "handle response maps a 401 to an authentication error even without a classifiable message" do
    response = mock_httparty_response(401, { "status" => "error", "message" => "unavailable" })

    assert_raises(Provider::Coinspot::AuthenticationError) do
      @provider.send(:handle_response, response)
    end
  end

  test "handle response maps a 403 to a permission error even without a classifiable message" do
    response = mock_httparty_response(403, { "status" => "error", "message" => "unavailable" })

    assert_raises(Provider::Coinspot::PermissionError) do
      @provider.send(:handle_response, response)
    end
  end

  test "handle response maps a non-2xx response with a classifiable message even at a non-401/403 status" do
    response = mock_httparty_response(400, { "message" => "Invalid key or signature" })

    assert_raises(Provider::Coinspot::AuthenticationError) do
      @provider.send(:handle_response, response)
    end
  end

  test "handle response falls back to a generic api error for a non-2xx response with no body" do
    response = mock_httparty_response(502, nil)

    error = assert_raises(Provider::Coinspot::ApiError) do
      @provider.send(:handle_response, response)
    end
    assert_match(/502/, error.message)
  end

  test "handle response rejects malformed payloads" do
    response = mock_httparty_response(200, [ "not", "a", "hash" ])

    error = assert_raises(Provider::Coinspot::ApiError) do
      @provider.send(:handle_response, response)
    end

    assert_equal "Malformed CoinSpot API response", error.message
  end

  test "handle response maps authentication errors" do
    assert_raises(Provider::Coinspot::AuthenticationError) do
      @provider.send(:handle_response, coinspot_error_response("Invalid key or signature"))
    end
  end

  test "handle response maps permission errors" do
    assert_raises(Provider::Coinspot::PermissionError) do
      @provider.send(:handle_response, coinspot_error_response("Permission denied"))
    end
  end

  test "handle response maps nonce errors" do
    assert_raises(Provider::Coinspot::NonceError) do
      @provider.send(:handle_response, coinspot_error_response("Invalid nonce"))
    end
  end

  test "handle response maps rate limit errors" do
    assert_raises(Provider::Coinspot::RateLimitError) do
      @provider.send(:handle_response, coinspot_error_response("Rate limit exceeded"))
    end
  end

  private

    def coinspot_error_response(message)
      mock_httparty_response(200, { "status" => "error", "message" => message })
    end

    def mock_httparty_response(code, body)
      OpenStruct.new(code: code, parsed_response: body)
    end
end
