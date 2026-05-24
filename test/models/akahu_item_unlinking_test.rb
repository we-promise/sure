require "test_helper"

class AkahuItemUnlinkingTest < ActiveSupport::TestCase
  test "unlink all only detaches holdings for the current family account provider links" do
    current_family = families(:dylan_family)
    other_family = families(:empty)
    security = securities(:aapl)

    current_account = Account.create!(
      family: current_family,
      owner: users(:family_admin),
      name: "Akahu Current Family Investment",
      balance: 100,
      cash_balance: 0,
      currency: "USD",
      accountable: Investment.create!(subtype: "brokerage")
    )
    other_account = Account.create!(
      family: other_family,
      owner: users(:empty),
      name: "Akahu Other Family Investment",
      balance: 100,
      cash_balance: 0,
      currency: "USD",
      accountable: Investment.create!(subtype: "brokerage")
    )

    current_item = AkahuItem.create!(
      family: current_family,
      name: "Current Akahu",
      app_token: "current-akahu-app-credential",
      user_token: "current-akahu-user-credential"
    )
    other_item = AkahuItem.create!(
      family: other_family,
      name: "Other Akahu",
      app_token: "other-akahu-app-credential",
      user_token: "other-akahu-user-credential"
    )

    current_akahu_account = current_item.akahu_accounts.create!(
      name: "Current Akahu Account",
      account_id: "akahu-current-account",
      currency: "USD"
    )
    other_akahu_account = other_item.akahu_accounts.create!(
      name: "Other Akahu Account",
      account_id: "akahu-other-account",
      currency: "USD"
    )

    current_link = AccountProvider.create!(account: current_account, provider: current_akahu_account)
    other_link = AccountProvider.create!(account: other_account, provider: other_akahu_account)

    current_holding = current_account.holdings.create!(
      security: security,
      qty: 1,
      price: 100,
      amount: 100,
      currency: "USD",
      date: Date.current,
      account_provider: current_link
    )
    other_holding = other_account.holdings.create!(
      security: security,
      qty: 1,
      price: 100,
      amount: 100,
      currency: "USD",
      date: Date.current,
      account_provider: other_link
    )

    current_item.unlink_all!(dry_run: false)

    assert_nil current_holding.reload.account_provider_id
    assert_not AccountProvider.exists?(current_link.id)
    assert_equal other_link.id, other_holding.reload.account_provider_id
    assert AccountProvider.exists?(other_link.id)
  end
end
