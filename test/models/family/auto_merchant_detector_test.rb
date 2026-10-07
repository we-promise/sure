require "test_helper"

class Family::AutoMerchantDetectorTest < ActiveSupport::TestCase
  include EntriesTestHelper, ProviderTestHelper

  setup do
    @family = families(:dylan_family)
    @account = @family.accounts.create!(name: "Rule test", balance: 100, currency: "USD", accountable: Depository.new)
    @llm_provider = mock
    Provider::Registry.stubs(:get_provider).with(:openai).returns(@llm_provider)
    Setting.stubs(:brand_fetch_client_id).returns("123")
    Setting.stubs(:brand_fetch_logo_size).returns(40)
  end

  test "auto detects transaction merchants" do
    txn1 = create_transaction(account: @account, name: "McDonalds").transaction
    txn2 = create_transaction(account: @account, name: "Chipotle").transaction
    txn3 = create_transaction(account: @account, name: "generic").transaction

    provider_response = provider_success_response([
      AutoDetectedMerchant.new(transaction_id: txn1.id, business_name: "McDonalds", business_url: "mcdonalds.com"),
      AutoDetectedMerchant.new(transaction_id: txn2.id, business_name: "Chipotle", business_url: "chipotle.com"),
      AutoDetectedMerchant.new(transaction_id: txn3.id, business_name: nil, business_url: nil)
    ])

    @llm_provider.expects(:auto_detect_merchants).returns(provider_response).once

    assert_difference "DataEnrichment.count", 2 do
      Family::AutoMerchantDetector.new(@family, transaction_ids: [ txn1.id, txn2.id, txn3.id ]).auto_detect
    end

    assert_equal "McDonalds", txn1.reload.merchant.name
    assert_equal "Chipotle", txn2.reload.merchant.name
    assert_equal "https://cdn.brandfetch.io/mcdonalds.com/icon/fallback/lettermark/w/40/h/40?c=123", txn1.reload.merchant.logo_url
    assert_equal "https://cdn.brandfetch.io/chipotle.com/icon/fallback/lettermark/w/40/h/40?c=123", txn2.reload.merchant.logo_url
    assert_nil txn3.reload.merchant

    # After auto-detection, only successfully detected transactions are locked
    # txn3 remains enrichable since it didn't get a merchant (allows retry)
    assert_equal 1, @account.transactions.reload.enrichable(:merchant_id).count
  end

  test "enhancing a provider merchant keeps its provider-supplied logo" do
    provider_logo = "https://plaid-merchant-logos.plaid.com/coffee_shop.png"
    merchant = ProviderMerchant.create!(source: "plaid", name: "Coffee Shop", logo_url: provider_logo)
    txn = create_transaction(account: @account, name: "COFFEE SHOP 123", merchant: merchant).transaction

    provider_response = provider_success_response([
      AutoDetectedMerchant.new(transaction_id: txn.id, business_name: "Coffee Shop", business_url: "https://www.coffeeshop.com")
    ])

    @llm_provider.expects(:auto_detect_merchants).returns(provider_response).once

    Family::AutoMerchantDetector.new(@family, transaction_ids: [ txn.id ]).auto_detect

    merchant.reload
    assert_equal "https://www.coffeeshop.com", merchant.website_url
    assert_equal provider_logo, merchant.logo_url
  end

  test "enhancing a provider merchant without a logo builds the logo from the website's domain" do
    merchant = ProviderMerchant.create!(source: "plaid", name: "Book Store")
    txn = create_transaction(account: @account, name: "BOOK STORE 42", merchant: merchant).transaction

    provider_response = provider_success_response([
      AutoDetectedMerchant.new(transaction_id: txn.id, business_name: "Book Store", business_url: "https://www.bookstore.com")
    ])

    @llm_provider.expects(:auto_detect_merchants).returns(provider_response).once

    Family::AutoMerchantDetector.new(@family, transaction_ids: [ txn.id ]).auto_detect

    assert_equal "https://cdn.brandfetch.io/bookstore.com/icon/fallback/lettermark/w/40/h/40?c=123", merchant.reload.logo_url
  end

  private
    AutoDetectedMerchant = Provider::LlmConcept::AutoDetectedMerchant
end
