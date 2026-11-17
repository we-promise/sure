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

  test "an invalid AI merchant name leaves that transaction unassigned without failing the batch" do
    invalid_txn = create_transaction(account: @account, name: "Weird").transaction
    valid_txn = create_transaction(account: @account, name: "Chipotle").transaction

    provider_response = provider_success_response([
      AutoDetectedMerchant.new(transaction_id: invalid_txn.id, business_name: Merchant::NO_MERCHANT_FILTER_VALUE, business_url: nil),
      AutoDetectedMerchant.new(transaction_id: valid_txn.id, business_name: "Chipotle", business_url: "chipotle.com")
    ])
    @llm_provider.expects(:auto_detect_merchants).returns(provider_response).once

    Family::AutoMerchantDetector.new(@family, transaction_ids: [ invalid_txn.id, valid_txn.id ]).auto_detect

    assert_nil invalid_txn.reload.merchant
    assert_equal "Chipotle", valid_txn.reload.merchant.name
  end

  # Regression: issue #3842. A family could previously get a globally-shared
  # ProviderMerchant created from LLM-extracted data derived from its own
  # transaction name/notes, which every other family could then match/reuse.
  test "creates a family-scoped merchant instead of a shared ProviderMerchant" do
    txn = create_transaction(account: @account, name: "Sushi Place").transaction

    provider_response = provider_success_response([
      AutoDetectedMerchant.new(transaction_id: txn.id, business_name: "Sushi Place", business_url: "sushiplace.example")
    ])
    @llm_provider.expects(:auto_detect_merchants).returns(provider_response).once

    assert_no_difference "ProviderMerchant.count" do
      Family::AutoMerchantDetector.new(@family, transaction_ids: [ txn.id ]).auto_detect
    end

    merchant = txn.reload.merchant
    assert_instance_of FamilyMerchant, merchant
    assert_equal @family, merchant.family
    assert_equal "Sushi Place", merchant.name
  end

  test "creates the family merchant through FamilyMerchant.find_or_create_with_name" do
    txn = create_transaction(account: @account, name: "Sushi Place").transaction
    merchant = @family.merchants.create!(name: "Sushi Place")

    provider_response = provider_success_response([
      AutoDetectedMerchant.new(transaction_id: txn.id, business_name: "Sushi Place", business_url: "sushiplace.example")
    ])
    @llm_provider.expects(:auto_detect_merchants).returns(provider_response).once
    Family::AutoMerchantDetector.any_instance.stubs(:find_matching_user_merchant).returns(nil)
    FamilyMerchant.expects(:find_or_create_with_name)
                  .with(@family, "Sushi Place", website_url: "sushiplace.example")
                  .returns([ merchant, false ])
                  .once

    Family::AutoMerchantDetector.new(@family, transaction_ids: [ txn.id ]).auto_detect

    assert_equal merchant, txn.reload.merchant
  end

  test "does not let one family's transaction text create or reuse another family's AI merchant" do
    other_family = families(:empty)
    other_account = other_family.accounts.create!(name: "Other", balance: 100, currency: "USD", accountable: Depository.new)

    txn1 = create_transaction(account: @account, name: "Shared Name Co").transaction
    txn2 = create_transaction(account: other_account, name: "Shared Name Co").transaction

    response1 = provider_success_response([
      AutoDetectedMerchant.new(transaction_id: txn1.id, business_name: "Shared Name Co", business_url: "sharedname.example")
    ])
    response2 = provider_success_response([
      AutoDetectedMerchant.new(transaction_id: txn2.id, business_name: "Shared Name Co", business_url: "sharedname.example")
    ])
    @llm_provider.expects(:auto_detect_merchants).returns(response1).once
    Family::AutoMerchantDetector.new(@family, transaction_ids: [ txn1.id ]).auto_detect

    @llm_provider.expects(:auto_detect_merchants).returns(response2).once
    Family::AutoMerchantDetector.new(other_family, transaction_ids: [ txn2.id ]).auto_detect

    merchant1 = txn1.reload.merchant
    merchant2 = txn2.reload.merchant

    assert_instance_of FamilyMerchant, merchant1
    assert_instance_of FamilyMerchant, merchant2
    assert_not_equal merchant1.id, merchant2.id
    assert_equal @family, merchant1.family
    assert_equal other_family, merchant2.family
  end

  # Legacy AI-sourced ProviderMerchants were created from some family's own
  # transaction text, so another family must not pick them up by url or name.
  test "does not reuse another family's legacy AI provider merchant" do
    legacy = ProviderMerchant.create!(name: "Crafted Co", source: "ai", website_url: "crafted.example")
    txn = create_transaction(account: @account, name: "Crafted Co purchase").transaction

    provider_response = provider_success_response([
      AutoDetectedMerchant.new(transaction_id: txn.id, business_name: "Crafted Co", business_url: "crafted.example")
    ])
    @llm_provider.expects(:auto_detect_merchants).returns(provider_response).once

    Family::AutoMerchantDetector.new(@family, transaction_ids: [ txn.id ]).auto_detect

    merchant = txn.reload.merchant
    assert_instance_of FamilyMerchant, merchant
    assert_not_equal legacy.id, merchant.id
  end

  test "reuses an AI provider merchant this family already uses" do
    mine = ProviderMerchant.create!(name: "Mine Co", source: "ai", website_url: "mine.example")
    used = create_transaction(account: @account, name: "Earlier Mine Co").transaction
    used.update!(merchant: mine)
    txn = create_transaction(account: @account, name: "Mine Co purchase").transaction

    provider_response = provider_success_response([
      AutoDetectedMerchant.new(transaction_id: txn.id, business_name: "Mine Co", business_url: "mine.example")
    ])
    @llm_provider.expects(:auto_detect_merchants).returns(provider_response).once

    assert_no_difference [ "ProviderMerchant.count", "FamilyMerchant.count" ] do
      Family::AutoMerchantDetector.new(@family, transaction_ids: [ txn.id ]).auto_detect
    end

    assert_equal mine.id, txn.reload.merchant.id
  end

  test "still reuses an existing shared provider merchant by website" do
    known = ProviderMerchant.create!(name: "Known Co", source: "plaid", website_url: "known.example")
    txn = create_transaction(account: @account, name: "Known Co purchase").transaction

    provider_response = provider_success_response([
      AutoDetectedMerchant.new(transaction_id: txn.id, business_name: "Known Co", business_url: "known.example")
    ])
    @llm_provider.expects(:auto_detect_merchants).returns(provider_response).once

    assert_no_difference [ "ProviderMerchant.count", "FamilyMerchant.count" ] do
      Family::AutoMerchantDetector.new(@family, transaction_ids: [ txn.id ]).auto_detect
    end

    assert_equal known.id, txn.reload.merchant.id
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
