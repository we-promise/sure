require "test_helper"

class SimplefinItem::UnlinkerTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @account = accounts(:investment)

    # Create a SimpleFin item and account
    @item = SimplefinItem.create!(family: @family, name: "SF Conn", access_url: "https://example.com/access")
    @sfa = SimplefinAccount.create!(
      simplefin_item: @item,
      name: "SF Brokerage",
      account_id: "sf_invest_1",
      account_type: "investment",
      currency: "USD",
      current_balance: 1000
    )

    # Legacy FK link (old path)
    @account.update!(simplefin_account_id: @sfa.id)
    @sfa.update!(account: @account)

    # New AccountProvider link
    @link = AccountProvider.create!(account: @account, provider: @sfa)

    # Create a security and a holding that references the AccountProvider link
    @security = Security.create!(ticker: "VTI", name: "Vanguard Total Market")
    @holding = Holding.create!(
      account: @account,
      security: @security,
      account_provider: @link,
      qty: 1.5,
      currency: "USD",
      date: Date.today,
      price: 100,
      amount: 150
    )
  end

  test "unlink_all! detaches holdings, destroys provider links, and clears legacy FK" do
    results = @item.unlink_all!

    # Observability payload
    assert_equal 1, results.size
    assert_equal @sfa.id, results.first[:sfa_id]

    # Provider link destroyed
    assert_nil AccountProvider.find_by(id: @link.id)

    # Holding detached from provider link but preserved
    assert @holding.reload
    assert_nil @holding.account_provider_id

    # Legacy FK cleared (SFA legacy association and Account FK)
    assert_nil @sfa.reload.account
    assert_nil @account.reload.simplefin_account_id
  end

  test "unlink_all! is idempotent when run twice" do
    @item.unlink_all!

    # Run again should be a no-op without raising
    results = @item.unlink_all!

    assert_equal 1, results.size
    assert_equal [], results.first[:provider_link_ids]

    # State remains clean
    assert_nil AccountProvider.find_by(provider: @sfa)
    # SFA upstream account_id should remain intact; legacy association should be cleared
    assert_nil @sfa.reload.account
    assert_nil @account.reload.simplefin_account_id
    assert_nil @holding.reload.account_provider_id
  end
end
