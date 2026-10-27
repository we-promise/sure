require "test_helper"

class MerchantsControllerTest < ActionDispatch::IntegrationTest
  include EntriesTestHelper

  setup do
    sign_in @user = users(:family_admin)
    @merchant = merchants(:netflix)
  end

  test "lists the merchant's transactions from every account" do
    create_transaction(account: accounts(:depository), name: "Netflix checking", merchant: @merchant)
    create_transaction(account: accounts(:credit_card), name: "Netflix card", merchant: @merchant)
    create_transaction(account: accounts(:depository), name: "Amazon order", merchant: merchants(:amazon))

    get merchant_url(@merchant)

    assert_response :success
    assert_match "Netflix checking", response.body
    assert_match "Netflix card", response.body
    assert_no_match "Amazon order", response.body
  end

  test "shows a provider merchant assigned to the family's transactions" do
    provider = ProviderMerchant.create!(name: "Coffee Co", source: "plaid")
    create_transaction(account: accounts(:depository), name: "Morning coffee", merchant: provider)

    get merchant_url(provider)

    assert_response :success
    assert_match "Morning coffee", response.body
  end

  test "leaves out transactions from accounts the user cannot access" do
    create_transaction(account: accounts(:investment), name: "Private Netflix", merchant: @merchant)
    create_transaction(account: accounts(:depository), name: "Shared Netflix", merchant: @merchant)

    sign_in users(:family_member)
    get merchant_url(@merchant)

    assert_response :success
    assert_match "Shared Netflix", response.body
    assert_no_match "Private Netflix", response.body
  end

  test "does not show another family's merchant" do
    other = families(:empty).merchants.create!(name: "Elsewhere")

    get merchant_url(other)

    assert_response :not_found
  end
end
