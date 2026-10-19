# frozen_string_literal: true

require "test_helper"

class CoinspotItem::SyncerTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @item = CoinspotItem.create!(family: @family, name: "CoinSpot", api_key: "k", api_secret: "s")
    @coinspot_account = @item.coinspot_accounts.create!(
      name: "CoinSpot",
      account_id: "combined",
      account_type: "combined",
      currency: "AUD",
      current_balance: 1000
    )
    @account = Account.create!(
      family: @family,
      name: "CoinSpot",
      balance: 0,
      currency: "AUD",
      accountable: Crypto.create!(subtype: "exchange")
    )
    AccountProvider.create!(account: @account, provider: @coinspot_account)
  end

  test "raises and captures debug log when linked account processing fails" do
    sync = @item.syncs.create!
    @item.expects(:import_latest_coinspot_data).returns(success: true)
    @item.expects(:process_accounts).returns([
      { coinspot_account_id: @coinspot_account.id, success: false, error: "boom" }
    ])
    @item.expects(:schedule_account_syncs).never
    DebugLogEntry.expects(:capture).with(has_entries(
      category: "provider_sync_error",
      level: "error",
      provider_key: "coinspot",
      family: @family,
      metadata: has_entries(coinspot_item_id: @item.id)
    ))

    error = assert_raises(StandardError) do
      CoinspotItem::Syncer.new(@item).perform_sync(sync)
    end

    assert_equal I18n.t("coinspot_item.syncer.processing_failed", count: 1), error.message
    assert sync.reload.failed?
    assert_equal error.message, sync.error
  end

  # schedule_account_syncs rescues per account and reports { success: false }
  # instead of raising, so discarding its result let a sync report success
  # while an account kept a stale balance.
  test "fails the sync when scheduling an account's balance sync fails" do
    sync = @item.syncs.create!
    @item.expects(:import_latest_coinspot_data).returns(success: true)
    @item.expects(:process_accounts).returns([
      { coinspot_account_id: @coinspot_account.id, success: true }
    ])
    @item.expects(:schedule_account_syncs).returns([
      { account_id: @account.id, success: false, error: "boom" }
    ])

    error = assert_raises(CoinspotItem::Syncer::ProcessingFailureError) do
      CoinspotItem::Syncer.new(@item).perform_sync(sync)
    end

    assert_equal I18n.t("coinspot_item.syncer.processing_failed", count: 1), error.message
    assert sync.reload.failed?
  end

  test "propagates per-account processor failures to the syncer" do
    CoinspotAccount::Processor.any_instance.stubs(:process).returns(
      success: false,
      failures: [ { kind: "holding", error: "boom" } ]
    )

    result = @item.process_accounts

    assert_equal false, result.first[:success]
    assert_equal "holding", result.first[:result][:failures].first[:kind]
  end
end
