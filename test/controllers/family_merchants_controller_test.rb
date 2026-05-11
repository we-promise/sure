require "test_helper"

class FamilyMerchantsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in @user = users(:family_admin)
    @merchant = merchants(:netflix)
  end

  test "index" do
    get family_merchants_path
    assert_response :success
  end

  test "new" do
    get new_family_merchant_path
    assert_response :success
  end

  test "should create merchant" do
    assert_difference("FamilyMerchant.count") do
      post family_merchants_url, params: { family_merchant: { name: "new merchant", color: "#000000" } }
    end

    assert_redirected_to family_merchants_path
  end

  test "should update merchant" do
    patch family_merchant_url(@merchant), params: { family_merchant: { name: "new name", color: "#000000" } }
    assert_redirected_to family_merchants_path
  end

  test "should destroy merchant" do
    assert_difference("FamilyMerchant.count", -1) do
      delete family_merchant_url(@merchant)
    end

    assert_redirected_to family_merchants_path
  end

  test "merge form uses configured default merchant color" do
    get merge_family_merchants_path

    assert_response :success
    assert_select "nav#mobile-settings-nav"
    assert_includes response.body, FamilyMerchant.default_color
  end

  test "enhance enqueues job and redirects" do
    assert_enqueued_with(job: EnhanceProviderMerchantsJob) do
      post enhance_family_merchants_path
    end

    assert_redirected_to family_merchants_path
  end

  test "should merge selected merchants into a new family merchant" do
    source = FamilyMerchant.create!(
      family: @user.family,
      name: "Merge Source Merchant",
      color: "#000000"
    )
    transaction = Transaction.create!(merchant: source)
    Entry.create!(
      account: accounts(:depository),
      entryable: transaction,
      name: "Merge source transaction",
      date: Date.current,
      amount: 10,
      currency: "USD"
    )

    assert_difference("FamilyMerchant.count", 0) do
      post perform_merge_family_merchants_path, params: {
        new_target_name: "Streaming",
        new_target_color: "#000000",
        source_ids: [ source.id ]
      }
    end

    target = FamilyMerchant.find_by!(family: @user.family, name: "Streaming")
    assert_redirected_to family_merchants_path
    assert_equal target, transaction.reload.merchant
    assert_not FamilyMerchant.exists?(source.id)
  end

  test "merge reassigns shared provider merchant only for current family" do
    provider_merchant = ProviderMerchant.create!(
      name: "Shared Provider Merchant #{SecureRandom.hex(4)}",
      source: "plaid",
      provider_merchant_id: "shared-provider-merchant-#{SecureRandom.hex(4)}"
    )
    target = FamilyMerchant.create!(
      family: @user.family,
      name: "Current Family Target Merchant",
      color: "#000000"
    )

    current_family_transaction = Transaction.create!(merchant: provider_merchant)
    Entry.create!(
      account: accounts(:depository),
      entryable: current_family_transaction,
      name: "Current family provider transaction",
      date: Date.current,
      amount: 10,
      currency: "USD"
    )

    other_family = Family.create!(name: "Other Family #{SecureRandom.hex(4)}", currency: "USD", locale: "en")
    other_depository = Depository.create!(subtype: "checking")
    other_account = Account.create!(
      family: other_family,
      accountable: other_depository,
      name: "Other Family Checking",
      currency: "USD",
      balance: 0
    )
    other_family_transaction = Transaction.create!(merchant: provider_merchant)
    Entry.create!(
      account: other_account,
      entryable: other_family_transaction,
      name: "Other family provider transaction",
      date: Date.current,
      amount: 10,
      currency: "USD"
    )

    assert_no_difference("ProviderMerchant.count") do
      post perform_merge_family_merchants_path, params: {
        target_id: target.id,
        source_ids: [ provider_merchant.id ]
      }
    end

    assert_redirected_to family_merchants_path
    assert_equal target, current_family_transaction.reload.merchant
    assert_equal provider_merchant, other_family_transaction.reload.merchant
    assert ProviderMerchant.exists?(provider_merchant.id)
  end

  test "merge preserves reviewed new target merchant color" do
    source = FamilyMerchant.create!(
      family: @user.family,
      name: "Color Source Merchant",
      color: "#000000"
    )

    post perform_merge_family_merchants_path, params: {
      new_target_name: "Color Target Merchant",
      new_target_color: "#123456",
      source_ids: [ source.id ]
    }

    target = FamilyMerchant.find_by!(family: @user.family, name: "Color Target Merchant")
    assert_redirected_to family_merchants_path
    assert_equal "#123456", target.color
  end

  test "merge normalizes new target merchant website" do
    source = FamilyMerchant.create!(
      family: @user.family,
      name: "Website Source Merchant",
      color: "#000000"
    )

    post perform_merge_family_merchants_path, params: {
      new_target_name: "Website Target",
      new_target_website_url: "https://www.Example.com/path",
      source_ids: [ source.id ]
    }

    target = FamilyMerchant.find_by!(family: @user.family, name: "Website Target")
    assert_redirected_to family_merchants_path
    assert_equal "example.com", target.website_url
  end

  test "merge rejects invalid new target merchant website" do
    source = FamilyMerchant.create!(
      family: @user.family,
      name: "Invalid Website Source Merchant",
      color: "#000000"
    )

    post perform_merge_family_merchants_path, params: {
      new_target_name: "Invalid Website Target",
      new_target_website_url: "https://bad host",
      source_ids: [ source.id ]
    }

    assert_redirected_to merge_family_merchants_path
    assert_equal I18n.t("family_merchants.perform_merge.invalid_website"), flash[:alert]
    assert FamilyMerchant.exists?(source.id)
    assert_nil FamilyMerchant.find_by(family: @user.family, name: "Invalid Website Target")
  end

  test "merge rejects conflicting existing and new targets" do
    source = FamilyMerchant.create!(
      family: @user.family,
      name: "Conflicting Source Merchant",
      color: "#000000"
    )

    post perform_merge_family_merchants_path, params: {
      target_id: @merchant.id,
      new_target_name: "Conflicting Target",
      source_ids: [ source.id ]
    }

    assert_redirected_to merge_family_merchants_path
    assert FamilyMerchant.exists?(source.id)
    assert_nil FamilyMerchant.find_by(family: @user.family, name: "Conflicting Target")
  end

  test "merge rolls back new target merchant when merge fails" do
    source = FamilyMerchant.create!(
      family: @user.family,
      name: "Rollback Source Merchant",
      color: "#000000"
    )
    source.errors.add(:base, "merge failed")
    Merchant::Merger.any_instance
      .stubs(:merge!)
      .raises(ActiveRecord::RecordInvalid.new(source))

    assert_no_difference("FamilyMerchant.count") do
      post perform_merge_family_merchants_path, params: {
        new_target_name: "Rollback Target Merchant",
        source_ids: [ source.id ]
      }
    end

    assert_redirected_to merge_family_merchants_path
    assert FamilyMerchant.exists?(source.id)
    assert_nil FamilyMerchant.find_by(family: @user.family, name: "Rollback Target Merchant")
  end

  test "bulk website update scopes merchants to current family and refreshes logos" do
    Setting.stubs(:brand_fetch_client_id).returns("test-client")
    Setting.stubs(:brand_fetch_logo_size).returns(128)

    provider_merchant = ProviderMerchant.create!(
      name: "Provider Merchant",
      source: "plaid",
      provider_merchant_id: "provider-merchant"
    )
    transactions(:one).update!(merchant: provider_merchant)

    other_family_merchant = FamilyMerchant.create!(
      family: families(:empty),
      name: "Other Family Merchant",
      color: "#000000"
    )

    post bulk_update_websites_family_merchants_path, params: {
      website_url: "https://www.example.com/path",
      merchant_ids: [ provider_merchant.id, other_family_merchant.id ]
    }

    assert_redirected_to family_merchants_path
    assert_equal "example.com", provider_merchant.reload.website_url
    assert_includes provider_merchant.logo_url, "cdn.brandfetch.io/example.com"
    assert_nil other_family_merchant.reload.website_url
  end

  test "bulk website update rejects malformed website domains" do
    post bulk_update_websites_family_merchants_path, params: {
      website_url: "https://bad host",
      merchant_ids: [ @merchant.id ]
    }

    assert_redirected_to bulk_websites_family_merchants_path
    assert_nil @merchant.reload.website_url
  end

  test "bulk website update handles merchant validation failures" do
    @merchant.errors.add(:website_url, "is invalid")
    FamilyMerchant.any_instance.stubs(:update!).raises(ActiveRecord::RecordInvalid.new(@merchant))

    post bulk_update_websites_family_merchants_path, params: {
      website_url: "example.com",
      merchant_ids: [ @merchant.id ]
    }

    assert_redirected_to bulk_websites_family_merchants_path
    assert_match "Could not update merchant websites", flash[:alert]
  end

  test "provider merchant logo clears when Brandfetch is unavailable" do
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

  test "family merchant logo clears when Brandfetch is unavailable" do
    merchant = FamilyMerchant.create!(
      family: @user.family,
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
