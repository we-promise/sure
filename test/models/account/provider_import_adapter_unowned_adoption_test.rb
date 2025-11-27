require "test_helper"

# Ensures an "unowned" composite row (no account_provider_id) is fully adopted on
# first collision: attributes are updated, external_id attached, and
# account_provider_id set to the importing provider.
class Account::ProviderImportAdapterUnownedAdoptionTest < ActiveSupport::TestCase
  test "adopts unowned holding on unique-index collision by updating attrs and provider ownership" do
    investment_account = accounts(:investment)
    adapter = Account::ProviderImportAdapter.new(investment_account)
    security = securities(:aapl)

    # Create a SimpleFin provider for this account (the importer)
    item = SimplefinItem.create!(family: families(:dylan_family), name: "SF Conn", access_url: "https://example.com/access")
    sfa = SimplefinAccount.create!(
      simplefin_item: item,
      name: "SF Invest",
      account_id: "sf_inv_unowned_claim",
      currency: "USD",
      account_type: "investment",
      current_balance: 1000
    )
    ap = AccountProvider.create!(account: investment_account, provider: sfa)

    holding_date = Date.today - 4.days

    # Existing composite row without provider ownership (unowned)
    existing_unowned = investment_account.holdings.create!(
      security: security,
      date: holding_date,
      qty: 1,
      price: 100,
      amount: 100,
      currency: "USD",
      account_provider_id: nil
    )

    # Import for SimpleFin with an external_id that will collide on composite key
    # Adapter should NOT create a new row, but should update the existing one:
    # - qty/price/amount/cost_basis updated
    # - external_id attached
    # - account_provider_id adopted to ap.id
    assert_no_difference "investment_account.holdings.count" do
      @result = adapter.import_holding(
        security: security,
        quantity: 2,
        amount: 220,
        currency: "USD",
        date: holding_date,
        price: 110,
        cost_basis: nil,
        external_id: "ext-unowned-1",
        source: "simplefin",
        account_provider_id: ap.id,
        delete_future_holdings: false
      )
    end

    existing_unowned.reload

    # Attributes updated
    assert_equal 2, existing_unowned.qty
    assert_equal 110, existing_unowned.price
    assert_equal 220, existing_unowned.amount

    # Ownership and external_id adopted
    assert_equal ap.id, existing_unowned.account_provider_id
    assert_equal "ext-unowned-1", existing_unowned.external_id

    # Adapter returns the same row
    assert_equal existing_unowned.id, @result.id

    # Idempotency: re-import should not create a duplicate and should return the same row
    assert_no_difference "investment_account.holdings.count" do
      again = adapter.import_holding(
        security: security,
        quantity: 2,
        amount: 220,
        currency: "USD",
        date: holding_date,
        price: 110,
        cost_basis: nil,
        external_id: "ext-unowned-1",
        source: "simplefin",
        account_provider_id: ap.id,
        delete_future_holdings: false
      )
      assert_equal existing_unowned.id, again.id
    end
  end
end
