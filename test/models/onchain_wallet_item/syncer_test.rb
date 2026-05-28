# frozen_string_literal: true

require "test_helper"

class OnchainWalletItem::SyncerTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @item = OnchainWalletItem.create!(family: @family, name: "On-chain Wallets")
  end

  test "perform_sync processes linked accounts without scheduling child account syncs" do
    wallet_account = @item.onchain_wallet_accounts.create!(
      chain: "bitcoin",
      wallet_address: "bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kygt080",
      asset_kind: "native",
      symbol: "BTC",
      name: "Bitcoin",
      currency: "USD",
      quantity: 1,
      current_balance: 50_000
    )
    account = Account.create_from_onchain_wallet_account(wallet_account)
    wallet_account.ensure_account_provider!(account)
    sync = @item.syncs.create!

    @item.expects(:import_latest_onchain_wallet_data).once
    @item.expects(:process_accounts).once
    @item.expects(:schedule_account_syncs).never
    Account.any_instance.expects(:sync_later).never

    OnchainWalletItem::Syncer.new(@item).perform_sync(sync)

    assert_empty account.syncs.reload
  end
end
