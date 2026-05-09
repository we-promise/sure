require "test_helper"

# End-to-end: a Plaid transaction with a known detailed_category lands on
# the user's matching Category via the shared matcher. Replaces the
# CategoryMatcher unit tests removed in the e64df9dd revert.
class Provider::Plaid::Transactions::CategoryMatchingTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @family.categories.bootstrap!
    @account = @family.accounts.create!(
      name: "Plaid Checking", balance: 0, currency: "USD",
      accountable: Depository.new
    )
    # No Plaid connection fixture exists yet — create one inline. Using the
    # generic Provider::Connection model directly (provider_key="plaid",
    # auth_type="embedded_link") matches how Plaid registers its adapter in
    # app/models/provider/plaid/adapter.rb.
    @connection = Provider::Connection.create!(
      family: @family, provider_key: "plaid", auth_type: "embedded_link",
      credentials: { access_token: "test" }, status: :healthy
    )
    @provider_account = Provider::Account.create!(
      account: @account,
      provider_connection: @connection,
      external_id: "ext-1",
      external_name: "Plaid Checking",
      external_type: "depository",
      currency: "USD",
      raw_payload: {},
      raw_transactions_payload: {
        "added" => [ {
          "transaction_id"            => "txn-1",
          "amount"                    => 12.34,
          "iso_currency_code"         => "USD",
          "date"                      => "2026-05-05",
          "merchant_name"             => "Pret",
          "personal_finance_category" => { "detailed" => "food_and_drink_restaurant" },
          "pending"                   => false
        } ]
      }
    )
  end

  test "matches detailed_category to user category via shared matcher" do
    Provider::Plaid::Transactions::Processor.new(@provider_account).process

    entry = @account.entries.find_by!(external_id: "txn-1", source: "plaid")
    # dylan_family fixture has a "Restaurants" subcategory under "Food & Drink";
    # the matcher correctly prefers the more-specific direct-alias hit
    # ("restaurant".pluralize == "Restaurants") over the parent.
    expected = @family.categories.find_by(name: "Restaurants")
    assert_equal expected.id, entry.transaction.category_id
  end

  test "leaves category nil when detailed_category is unknown" do
    @provider_account.update!(raw_transactions_payload: {
      "added" => [ {
        "transaction_id"            => "txn-2",
        "amount"                    => 1.0, "iso_currency_code" => "USD",
        "date"                      => "2026-05-05", "merchant_name" => "X",
        "personal_finance_category" => { "detailed" => "totally_not_a_real_category" },
        "pending"                   => false
      } ]
    })
    Provider::Plaid::Transactions::Processor.new(@provider_account).process
    entry = @account.entries.find_by!(external_id: "txn-2", source: "plaid")
    assert_nil entry.transaction.category_id
  end
end
