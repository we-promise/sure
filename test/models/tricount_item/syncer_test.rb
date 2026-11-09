# frozen_string_literal: true

require "test_helper"
require_relative "../../support/tricount_test_helper"

class TricountItem::SyncerTest < ActiveSupport::TestCase
  include TricountTestHelper

  setup do
    @family = families(:empty)
    @item = @family.tricount_items.create!(name: "Tricount", sharing_tokens: SHARING_TOKEN)
    @provider = mock
    @provider.stubs(:synchronize!)
    @item.stubs(:tricount_provider).returns(@provider)
    @item.stubs(:schedule_account_syncs)
  end

  def sync_item
    sync = Sync.create!(syncable: @item)
    TricountItem::Syncer.new(@item).perform_sync(sync)
    sync.reload
  end

  def link_account
    tricount_account = @item.tricount_accounts.new
    tricount_account.upsert_from_tricount!(tricount_registry)
    tricount_account.assign_member!(ME)
    account = @family.accounts.create!(name: "Weekend trip", balance: 0, currency: "EUR", accountable: Depository.new)
    tricount_account.ensure_account_provider!(account)
  end

  test "a clean sync is healthy" do
    @provider.stubs(:registry).returns(tricount_registry)

    assert_equal 0, sync_item.sync_stats["total_errors"]
  end

  test "a tricount that can't be read leaves the sync unhealthy and logs it for support" do
    @provider.stubs(:registry).raises(Provider::Tricount::Error.new("Tricount server error (502). Please try again later.", :server_error))

    sync = nil
    assert_difference -> { DebugLogEntry.where(provider_key: "tricount").count }, 1 do
      sync = sync_item
    end

    assert_equal 1, sync.sync_stats["total_errors"]
    assert_equal "import_error", sync.sync_stats["errors"].sole["category"]
  end

  # Its snapshot is the last one read: taken as today's balance, it would be
  # anchored on today and distort the history once the tricount reads again.
  test "an account whose tricount can't be read is left as it was" do
    link_account
    @provider.stubs(:registry).returns(nil)
    TricountAccount::Processor.any_instance.expects(:process).never

    sync = sync_item

    assert_equal 1, sync.sync_stats["total_errors"]
  end

  test "an account whose tricount was read is processed" do
    link_account
    @provider.stubs(:registry).returns(tricount_registry)
    TricountAccount::Processor.any_instance.expects(:process).once.returns({})

    sync_item
  end

  test "an account that can't be processed leaves the sync unhealthy" do
    link_account
    @provider.stubs(:registry).returns(tricount_registry)
    TricountAccount::Processor.any_instance.stubs(:process).raises(ActiveRecord::RecordInvalid)

    sync = sync_item

    assert_equal 1, sync.sync_stats["total_errors"]
    assert_equal "account_processing_error", sync.sync_stats["errors"].sole["category"]
    assert_equal @item.tricount_accounts.sole.id, sync.sync_stats["errors"].sole["tricount_account_id"], "support needs to know which account"
  end

  # schedule_account_syncs reports an account it couldn't queue instead of
  # raising; that account's history isn't recalculated.
  test "an account sync that can't be scheduled leaves the sync unhealthy" do
    link_account
    @provider.stubs(:registry).returns(tricount_registry)
    @item.stubs(:schedule_account_syncs).returns([ { account_id: @item.accounts.first.id, success: false, error: "queue unavailable" } ])

    sync = nil
    assert_difference -> { DebugLogEntry.where(provider_key: "tricount").count }, 1 do
      sync = sync_item
    end

    assert_equal 1, sync.sync_stats["total_errors"]
    assert_equal "account_sync_error", sync.sync_stats["errors"].sole["category"]
    assert_equal @item.accounts.first.id, sync.sync_stats["errors"].sole["account_id"], "support needs to know which account"
  end

  # As with the other providers, a disabled account keeps the data it has.
  test "a disabled account is left as it is" do
    link_account
    account = @item.tricount_accounts.sole.current_account
    account.update_columns(status: "disabled")
    @provider.stubs(:registry).returns(tricount_registry)

    sync_item

    assert_equal BigDecimal("0"), account.reload.balance
    assert_empty account.entries.where(source: "tricount")
  end

  test "a refused session is logged for support" do
    @provider.stubs(:synchronize!).raises(Provider::Tricount::AuthenticationError.new("Tricount refused the session (401)", :unauthorized))
    sync = Sync.create!(syncable: @item)

    assert_difference -> { DebugLogEntry.where(provider_key: "tricount", level: "error").count }, 1 do
      assert_raises(Provider::Tricount::AuthenticationError) { TricountItem::Syncer.new(@item).perform_sync(sync) }
    end
    assert @item.reload.requires_update?
  end

  test "a sync that fails outright is logged for support" do
    @provider.stubs(:synchronize!).raises(Provider::Tricount::Error.new("Tricount server error (502). Please try again later.", :server_error))
    sync = Sync.create!(syncable: @item)

    assert_difference -> { DebugLogEntry.where(provider_key: "tricount", level: "error").count }, 1 do
      assert_raises(Provider::Tricount::Error) { TricountItem::Syncer.new(@item).perform_sync(sync) }
    end
    assert_equal "Provider::Tricount::Error", DebugLogEntry.where(provider_key: "tricount").order(:created_at).last.metadata["error_class"]
  end
end
