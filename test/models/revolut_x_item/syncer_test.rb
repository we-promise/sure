# frozen_string_literal: true

require "test_helper"

class RevolutXItem::SyncerTest < ActiveSupport::TestCase
  setup do
    @item = revolut_x_items(:one)
    @item.revolut_x_accounts.destroy_all
  end

  test "missing credentials fail the sync with the credentials text and ask for an update" do
    item = revolut_x_items(:awaiting_api_key)
    RevolutXItem::Importer.any_instance.expects(:import).never

    sync = perform_sync(item)

    assert sync.failed?
    assert_equal I18n.t("revolut_x_items.syncer.credentials_invalid"), sync.error
    assert item.reload.requires_update?
  end

  test "an authentication failure fails the sync with the credentials text, and the next successful import restores good status" do
    provider = mock
    provider.stubs(:get_balances).raises(Provider::RevolutX::AuthenticationError, "bad key")
    RevolutXItem.any_instance.stubs(:revolut_x_provider).returns(provider)

    sync = perform_sync(@item)

    assert sync.failed?
    assert_equal I18n.t("revolut_x_items.syncer.credentials_invalid"), sync.error
    assert @item.reload.requires_update?

    RevolutXItem::Importer.any_instance.stubs(:import).returns(success: true)

    assert perform_sync(@item).completed?
    assert @item.reload.good?
  end

  test "a successful import flags unlinked accounts for setup" do
    @item.revolut_x_accounts.create!(name: "Revolut X", account_id: "default", account_type: "exchange", currency: "USD")
    @item.expects(:import_latest_revolut_x_data).returns(success: true)
    @item.expects(:process_accounts).never

    RevolutXItem::Syncer.new(@item).perform_sync(@item.syncs.create!)

    assert @item.reload.pending_account_setup?
  end

  test "processes and schedules linked accounts" do
    link_account
    @item.expects(:import_latest_revolut_x_data).returns(success: true)
    @item.expects(:process_accounts).returns([])
    @item.expects(:schedule_account_syncs).returns([])

    RevolutXItem::Syncer.new(@item).perform_sync(@item.syncs.create!)

    assert_not @item.reload.pending_account_setup?
  end

  test "an account that fails to process completes the sync with the failure in its stats" do
    link_account
    sync = @item.syncs.create!
    @item.expects(:import_latest_revolut_x_data).returns(success: true)
    @item.expects(:process_accounts).returns([ { revolut_x_account_id: "x", success: false, error: "no FX rate" } ])
    @item.expects(:schedule_account_syncs).returns([])

    RevolutXItem::Syncer.new(@item).perform_sync(sync)

    assert_equal [ I18n.t("revolut_x_items.syncer.account_processing_failed", count: 1) ],
                 sync.reload.sync_stats["errors"].map { |error| error["message"] }
  end

  test "an account sync that fails to schedule completes the sync with the failure in its stats" do
    link_account
    sync = @item.syncs.create!
    @item.expects(:import_latest_revolut_x_data).returns(success: true)
    @item.expects(:process_accounts).returns([])
    @item.expects(:schedule_account_syncs).returns([ { account_id: "x", success: false, error: "boom" } ])

    RevolutXItem::Syncer.new(@item).perform_sync(sync)

    assert_equal [ I18n.t("revolut_x_items.syncer.account_sync_failed", count: 1) ],
                 sync.reload.sync_stats["errors"].map { |error| error["message"] }
  end

  private

    def perform_sync(item)
      Sync.create!(syncable: item).tap(&:perform).reload
    end

    def link_account
      revolut_x_account = @item.revolut_x_accounts.create!(name: "Revolut X", account_id: "default", account_type: "exchange", currency: "USD")
      AccountProvider.create!(account: accounts(:crypto), provider: revolut_x_account)
    end
end
