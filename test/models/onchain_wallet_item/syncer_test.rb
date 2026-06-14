# frozen_string_literal: true

require "test_helper"

class OnchainWalletItem::SyncerTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @item = OnchainWalletItem.create!(family: @family, name: "On-chain Wallets")
  end

  test "perform_sync imports, processes linked accounts, and schedules account syncs" do
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

    # Import reports the account as changed this run.
    @item.expects(:import_latest_onchain_wallet_data).once.returns(changed_account_ids: [ wallet_account.id ])
    @item.expects(:process_accounts).once
    # The syncer schedules per-account balance recalculation so the value chart
    # (Balance records) is populated after import.
    @item.expects(:schedule_account_syncs).once

    OnchainWalletItem::Syncer.new(@item).perform_sync(sync)
  end

  test "perform_sync skips processing when no account changed (idempotent)" do
    wallet_account = @item.onchain_wallet_accounts.create!(
      chain: "bitcoin", wallet_address: "bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kygt080",
      asset_kind: "native", symbol: "BTC", name: "Bitcoin", currency: "USD",
      quantity: 1, current_balance: 50_000
    )
    account = Account.create_from_onchain_wallet_account(wallet_account)
    wallet_account.ensure_account_provider!(account)
    sync = @item.syncs.create!

    @item.expects(:import_latest_onchain_wallet_data).once.returns(changed_account_ids: [])
    @item.expects(:process_accounts).never
    @item.expects(:schedule_account_syncs).never

    OnchainWalletItem::Syncer.new(@item).perform_sync(sync)
  end
end
