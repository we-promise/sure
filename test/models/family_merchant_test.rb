require "test_helper"

class FamilyMerchantTest < ActiveSupport::TestCase
  test "logo clears when Brandfetch is unavailable" do
    merchant = FamilyMerchant.create!(
      family: families(:dylan_family),
      name: "Logo Clearing Family Merchant",
      color: "#000000",
      website_url: "old.example.com"
    )
    merchant.update_column(:logo_url, "https://cdn.brandfetch.io/old.example.com/icon")

    Setting.stubs(:brand_fetch_client_id).returns(nil)
    merchant.update!(website_url: "new.example.com")

    assert_nil merchant.reload.logo_url
  end
end
