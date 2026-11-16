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

  test "edit link returns to the merchant page it was opened from" do
    get merchant_url(@merchant, page: 2)

    assert_select "a[href=?]", edit_family_merchant_path(@merchant, return_to: merchant_path(@merchant, page: 2))
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

  test "averages spending over purchases only" do
    create_transaction(account: accounts(:depository), name: "Netflix plan", merchant: @merchant, amount: 100)
    create_transaction(account: accounts(:depository), name: "Netflix refund", merchant: @merchant, amount: -100)

    get merchant_url(@merchant)

    assert_response :success
    assert_select "dt", text: "Average transaction" do |dt|
      assert_equal "$100.00", dt.first.next_element.text.strip
    end
  end

  test "does not show a provider merchant used only on accounts the user cannot access" do
    provider = ProviderMerchant.create!(name: "Private Co", source: "plaid")
    create_transaction(account: accounts(:investment), name: "Private purchase", merchant: provider)

    sign_in users(:family_member)
    get merchant_url(provider)

    assert_response :not_found
  end

  test "does not show another family's merchant" do
    other = families(:empty).merchants.create!(name: "Elsewhere")

    get merchant_url(other)

    assert_response :not_found
  end

  test "filters the list and summary by the search" do
    create_transaction(account: accounts(:depository), name: "Netflix basic", merchant: @merchant, amount: 10)
    create_transaction(account: accounts(:depository), name: "Netflix premium", merchant: @merchant, amount: 20)

    get merchant_url(@merchant, q: { search: "premium" })

    assert_response :success
    assert_match "Netflix premium", response.body
    assert_no_match "Netflix basic", response.body
    assert_select "dt", text: "Total spending" do |dt|
      assert_equal "$20.00", dt.first.next_element.text.strip
    end
    assert_select "#merchant-transaction-filters form[action^=?]", clear_filter_merchant_path(@merchant)
  end

  test "leaves spending out of the summary when the type filter excludes expenses" do
    create_transaction(account: accounts(:depository), name: "Netflix plan", merchant: @merchant, amount: 10)
    create_transaction(account: accounts(:depository), name: "Netflix refund", merchant: @merchant, amount: -10)

    get merchant_url(@merchant, q: { types: [ "income" ] })

    assert_response :success
    assert_select "dt", text: "Total spending", count: 0
    assert_select "dt", text: "Average transaction", count: 0
  end

  test "keeps the page size when filtering" do
    get merchant_url(@merchant, per_page: 10, q: { search: "plan" })

    assert_select "#merchant-transactions-search input[type=hidden][name=per_page][value='10']"
    assert_select "a[href=?]", merchant_path(@merchant, per_page: 10), text: "Clear filters"
  end

  test "keeps the page's merchant when another one is passed in the filters" do
    create_transaction(account: accounts(:depository), name: "Netflix plan", merchant: @merchant)
    create_transaction(account: accounts(:depository), name: "Amazon order", merchant: merchants(:amazon))

    get merchant_url(@merchant, q: { merchants: [ merchants(:amazon).name ] })

    assert_response :success
    assert_match "Netflix plan", response.body
    assert_no_match "Amazon order", response.body
  end

  test "clearing a filter keeps the others" do
    delete clear_filter_merchant_url(@merchant, param_key: "categories", param_value: "Food", q: { search: "plan", categories: [ "Food", "Income" ] })

    assert_redirected_to merchant_path(@merchant, q: { search: "plan", categories: [ "Income" ] })
  end

  test "does not clear filters on another family's merchant" do
    other = families(:empty).merchants.create!(name: "Elsewhere")

    delete clear_filter_merchant_url(other, param_key: "search")

    assert_response :not_found
  end
end
