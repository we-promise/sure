require "test_helper"

class ProviderMerchant::EnhancerTest < ActiveSupport::TestCase
  include EntriesTestHelper, ProviderTestHelper

  setup do
    @family = families(:dylan_family)
    @account = @family.accounts.create!(name: "Enhancer test", balance: 100, currency: "USD", accountable: Depository.new)
    @llm_provider = mock
    Provider::Registry.stubs(:get_provider).with(:openai).returns(@llm_provider)
    Setting.stubs(:brand_fetch_client_id).returns("test_client_id")
    Setting.stubs(:brand_fetch_logo_size).returns(40)
  end

  test "enhances provider merchants with website and logo" do
    merchant = ProviderMerchant.create!(source: "lunchflow", name: "Walmart", provider_merchant_id: "lf_walmart")
    create_transaction(account: @account, name: "Walmart purchase", merchant: merchant)

    provider_response = provider_success_response([
      EnhancedMerchant.new(merchant_id: merchant.id, business_url: "walmart.com")
    ])

    @llm_provider.expects(:enhance_provider_merchants).returns(provider_response).once

    result = ProviderMerchant::Enhancer.new(@family).enhance

    assert_equal 1, result[:enhanced]
    assert_equal "walmart.com", merchant.reload.website_url
    assert_equal "https://cdn.brandfetch.io/walmart.com/icon/fallback/lettermark/w/40/h/40?c=test_client_id", merchant.logo_url
  end

  test "skips merchants when LLM returns null" do
    merchant = ProviderMerchant.create!(source: "lunchflow", name: "Local Diner", provider_merchant_id: "lf_local")
    create_transaction(account: @account, name: "Local diner", merchant: merchant)

    provider_response = provider_success_response([
      EnhancedMerchant.new(merchant_id: merchant.id, business_url: nil)
    ])

    @llm_provider.expects(:enhance_provider_merchants).returns(provider_response).once

    result = ProviderMerchant::Enhancer.new(@family).enhance

    assert_equal 0, result[:enhanced]
    assert_nil merchant.reload.website_url
  end

  test "deduplicates merchants by website_url" do
    lunchflow_merchant = ProviderMerchant.create!(source: "lunchflow", name: "Walmart", provider_merchant_id: "lf_walmart")
    ai_merchant = ProviderMerchant.create!(source: "ai", name: "Walmart", website_url: "walmart.com",
      logo_url: "https://cdn.brandfetch.io/walmart.com/icon/fallback/lettermark/w/40/h/40?c=test_client_id")

    txn1 = create_transaction(account: @account, name: "Walmart purchase 1", merchant: lunchflow_merchant).transaction
    txn2 = create_transaction(account: @account, name: "Walmart purchase 2", merchant: ai_merchant).transaction

    provider_response = provider_success_response([
      EnhancedMerchant.new(merchant_id: lunchflow_merchant.id, business_url: "walmart.com")
    ])

    @llm_provider.expects(:enhance_provider_merchants).returns(provider_response).once

    result = ProviderMerchant::Enhancer.new(@family).enhance

    assert_equal 1, result[:enhanced]
    assert_equal 1, result[:deduplicated]
    assert_equal "walmart.com", lunchflow_merchant.reload.website_url

    # AI merchant's transactions should be reassigned to the lunchflow merchant
    assert_equal lunchflow_merchant.id, txn2.reload.merchant_id
    assert_equal lunchflow_merchant.id, txn1.reload.merchant_id
  end

  test "returns zero counts when no LLM provider" do
    Provider::Registry.stubs(:get_provider).with(:openai).returns(nil)

    result = ProviderMerchant::Enhancer.new(@family).enhance

    assert_equal 0, result[:enhanced]
    assert_equal 0, result[:deduplicated]
  end

  test "returns zero counts when no unenhanced merchants" do
    result = ProviderMerchant::Enhancer.new(@family).enhance

    assert_equal 0, result[:enhanced]
    assert_equal 0, result[:deduplicated]
  end

  test "skips merchants that already have website_url" do
    merchant = ProviderMerchant.create!(source: "lunchflow", name: "Amazon", provider_merchant_id: "lf_amazon", website_url: "amazon.com")
    create_transaction(account: @account, name: "Amazon order", merchant: merchant)

    # Should not call LLM because no merchants need enhancement
    @llm_provider.expects(:enhance_provider_merchants).never

    result = ProviderMerchant::Enhancer.new(@family).enhance

    assert_equal 0, result[:enhanced]
  end

  private
    EnhancedMerchant = Provider::LlmConcept::EnhancedMerchant
end
