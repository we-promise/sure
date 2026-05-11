require "test_helper"

class ProviderMerchantTest < ActiveSupport::TestCase
  test "logo clears when Brandfetch is unavailable" do
    provider_merchant = ProviderMerchant.create!(
      name: "Logo Clearing Provider Merchant",
      source: "plaid",
      provider_merchant_id: "logo-clearing-provider-merchant",
      website_url: "old.example.com"
    )
    provider_merchant.update_column(:logo_url, "https://cdn.brandfetch.io/old.example.com/icon")

    Setting.stubs(:brand_fetch_client_id).returns(nil)
    provider_merchant.update!(website_url: "new.example.com")
    provider_merchant.generate_logo_url_from_website!

    assert_nil provider_merchant.reload.logo_url
  end
end
