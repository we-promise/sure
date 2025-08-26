require "test_helper"

class BankProvidersMercuryTest < ActiveSupport::TestCase
  test "list_accounts signs request" do
    provider = BankProviders::Mercury.new(api_key: "key", api_secret: "secret")

    Time.stub :now, Time.at(1_700_000_000) do
      path = "/accounts"
      payload = "1700000000GET#{path}"
      expected_signature = OpenSSL::HMAC.hexdigest("SHA256", "secret", payload)

      stub_request(:get, "https://api.mercury.com/api/v1/accounts").with(
        headers: {
          "X-Mercury-Api-Key" => "key",
          "X-Mercury-Timestamp" => "1700000000",
          "X-Mercury-Signature" => expected_signature,
          "Content-Type" => "application/json"
        }
      ).to_return(body: "{\"accounts\": []}", headers: { "Content-Type" => "application/json" })

      assert_equal({"accounts" => []}, provider.list_accounts)
    end
  end
end
