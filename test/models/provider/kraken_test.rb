# frozen_string_literal: true

require "test_helper"

class Provider::KrakenTest < ActiveSupport::TestCase
  OFFICIAL_SAMPLE_SECRET = "kQH5HW/8p1uGOVjbgWA7FunAmGO8lsSUXNsu3eow76sz84Q18fWxnyRzBHCd3pd5nE9qa99HAZtuZuj6F1huXg==" # pipelock:ignore public Kraken docs signing sample
  OFFICIAL_SAMPLE_SIGNATURE = "4/dpxb3iT4tp/ZCVEwSnEsLxx0bqyhLpdfOpc6fn7OR8+UClSV5n9E6aSS8MPtnRfp32bAb0nmbRn6H8ndwLUQ=="

  setup do
    @provider = Provider::Kraken.new(api_key: "test_key", api_secret: OFFICIAL_SAMPLE_SECRET, nonce_generator: -> { "1616492376594" })
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
    refute_equal OFFICIAL_SAMPLE_SECRET, headers["API-Sign"]
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
