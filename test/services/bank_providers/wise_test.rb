require "test_helper"

class BankProvidersWiseTest < ActiveSupport::TestCase
  test "list_accounts sends bearer token" do
    provider = BankProviders::Wise.new(api_token: "token")

    stub_request(:get, "https://api.transferwise.com/v1/profiles").with(
      headers: {
        "Authorization" => "Bearer token",
        "Content-Type" => "application/json"
      }
    ).to_return(body: "{\"profiles\": []}", headers: { "Content-Type" => "application/json" })

    assert_equal({"profiles" => []}, provider.list_accounts)
  end
end
