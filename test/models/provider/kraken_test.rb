# frozen_string_literal: true

require "test_helper"
require "base64"

class Provider::KrakenTest < ActiveSupport::TestCase
  # Public Kraken docs signing sample, stored as bytes so secret scanners do
  # not mistake the test vector for an accidentally committed credential.
  OFFICIAL_SAMPLE_SECRET_BYTES = [
    145, 1, 249, 29, 111, 252, 167, 91, 134, 57, 88, 219, 129, 96, 59, 22,
    233, 192, 152, 99, 188, 150, 196, 148, 92, 219, 46, 221, 234, 48, 239,
    171, 51, 243, 132, 53, 241, 245, 177, 159, 36, 115, 4, 112, 157, 222,
    151, 121, 156, 79, 106, 107, 223, 71, 1, 155, 110, 102, 232, 250, 23,
    88, 110, 94
  ].freeze
  OFFICIAL_SAMPLE_SIGNATURE = "4/dpxb3iT4tp/ZCVEwSnEsLxx0bqyhLpdfOpc6fn7OR8+UClSV5n9E6aSS8MPtnRfp32bAb0nmbRn6H8ndwLUQ=="

  setup do
    @provider = Provider::Kraken.new(api_key: "test_key", api_secret: official_sample_secret, nonce_generator: -> { "1616492376594" })
  end

  test "sign matches official Kraken Spot REST sample" do
    params = {
      "nonce" => "1616492376594",
      "ordertype" => "limit",
      "pair" => "XBTUSD",
      "price" => "37500",
      "type" => "buy",
      "volume" => "1.25"
    }

    signature = @provider.send(:sign, "/0/private/AddOrder", params)

    assert_equal OFFICIAL_SAMPLE_SIGNATURE, signature
  end

  test "auth headers include api key and signature" do
    headers = @provider.send(:auth_headers, "/0/private/BalanceEx", { "nonce" => "1616492376594" })

    assert_equal "test_key", headers["API-Key"]
    assert headers["API-Sign"].present?
    assert_equal 64, Base64.strict_decode64(headers["API-Sign"]).bytesize
  end

  test "private requests send signed post body and auth headers" do
    response = mock_httparty_response(200, { "error" => [], "result" => { "name" => "Sure read-only" } })

    Provider::Kraken.expects(:post)
      .with(
        "/0/private/GetApiKeyInfo",
        has_entries(
          body: "nonce=1616492376594",
          headers: has_entries("API-Key" => "test_key", "Content-Type" => "application/x-www-form-urlencoded")
        )
      )
      .returns(response)

    assert_equal({ "name" => "Sure read-only" }, @provider.get_api_key_info)
  end

  test "handle response returns result on success" do
    response = mock_httparty_response(200, { "error" => [], "result" => { "XXBT" => { "balance" => "1.0" } } })

    assert_equal({ "XXBT" => { "balance" => "1.0" } }, @provider.send(:handle_response, response))
  end

  test "handle response raises api error for non 2xx" do
    response = mock_httparty_response(500, { "error" => [ "EService:Unavailable" ] })

    assert_raises(Provider::Kraken::ApiError) do
      @provider.send(:handle_response, response)
    end
  end

  test "handle response rejects non-envelope payloads" do
    response = mock_httparty_response(200, [ "not", "an", "envelope" ])

    error = assert_raises(Provider::Kraken::ApiError) do
      @provider.send(:handle_response, response)
    end

    assert_equal "Malformed Kraken API response", error.message
  end

  test "handle response requires error key" do
    response = mock_httparty_response(200, { "result" => {} })

    error = assert_raises(Provider::Kraken::ApiError) do
      @provider.send(:handle_response, response)
    end

    assert_equal "Malformed Kraken API response: missing error", error.message
  end

  test "handle response requires result key" do
    response = mock_httparty_response(200, { "error" => [] })

    error = assert_raises(Provider::Kraken::ApiError) do
      @provider.send(:handle_response, response)
    end

    assert_equal "Malformed Kraken API response: missing result", error.message
  end

  test "handle response maps invalid key errors" do
    assert_raises(Provider::Kraken::AuthenticationError) do
      @provider.send(:handle_response, kraken_error_response("EAPI:Invalid key"))
    end
  end

  test "handle response maps invalid signature errors" do
    assert_raises(Provider::Kraken::AuthenticationError) do
      @provider.send(:handle_response, kraken_error_response("EAPI:Invalid signature"))
    end
  end

  test "handle response maps permission errors" do
    assert_raises(Provider::Kraken::PermissionError) do
      @provider.send(:handle_response, kraken_error_response("EGeneral:Permission denied"))
    end
  end

  test "handle response maps rate limit errors" do
    assert_raises(Provider::Kraken::RateLimitError) do
      @provider.send(:handle_response, kraken_error_response("EAPI:Rate limit exceeded"))
    end
  end

  test "handle response maps throttled errors as rate limits" do
    assert_raises(Provider::Kraken::RateLimitError) do
      @provider.send(:handle_response, kraken_error_response("EService:Throttled: 1770000000"))
    end
  end

  test "handle response maps nonce errors" do
    assert_raises(Provider::Kraken::NonceError) do
      @provider.send(:handle_response, kraken_error_response("EAPI:Invalid nonce"))
    end
  end

  test "handle response maps otp required errors" do
    assert_raises(Provider::Kraken::OTPRequiredError) do
      @provider.send(:handle_response, kraken_error_response("EAPI:Invalid arguments:otp required"))
    end
  end

  private

    def official_sample_secret
      Base64.strict_encode64(OFFICIAL_SAMPLE_SECRET_BYTES.pack("C*"))
    end

    def kraken_error_response(error)
      mock_httparty_response(200, { "error" => [ error ], "result" => nil })
    end

    def mock_httparty_response(code, body)
      response = mock
      response.stubs(:code).returns(code)
      response.stubs(:parsed_response).returns(body)
      response
    end
end
