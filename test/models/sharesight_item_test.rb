require "test_helper"

class SharesightItemTest < ActiveSupport::TestCase
  test "accounts uses portfolios that are already loaded" do
    family = families(:dylan_family)
    item = family.sharesight_items.create!(name: "Sharesight", client_id: "client-id", client_secret: "client-secret")
    2.times do |i|
      account = family.accounts.create!(name: "Shares #{i}", balance: 0, currency: "AUD", accountable: Investment.new)
      item.sharesight_accounts.create!(name: "Shares #{i}", currency: "AUD", sharesight_account_id: i.to_s).ensure_account_provider!(account)
    end

    loaded = SharesightItem.includes(sharesight_accounts: [ :account, :linked_account ]).find(item.id)

    assert_queries_count(0) { assert_equal 2, loaded.accounts.size }
  end
end
