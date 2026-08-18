require "test_helper"

class OpenBankingIoItem::SyncerTest < ActiveSupport::TestCase
  setup do
    @item = OpenBankingIoItem.create!(
      family: families(:dylan_family),
      name: "Test open-banking.io",
      api_base_url: "https://open-banking.io",
      api_key: "test-api-key",
      private_key: "test-private-key"
    )
    @syncer = OpenBankingIoItem::Syncer.new(@item)
  end

  # Fix 8: an unexpected sync error must be captured to DebugLogEntry (surfacing
  # on /settings/debug), not only written to Rails.logger, before it is re-raised
  # as the sanitized SafeSyncError.
  test "captures an unexpected sync error to DebugLogEntry before raising SafeSyncError" do
    sync = Sync.create!(syncable: @item)
    @item.stubs(:import_latest_open_banking_io_data).raises(StandardError.new("kaboom"))

    assert_difference -> { DebugLogEntry.where(category: "provider_sync_error").count }, +1 do
      assert_raises(OpenBankingIoItem::Syncer::SafeSyncError) do
        @syncer.perform_sync(sync)
      end
    end
  end

  # Sync has no status_text column on this Rails version, so update_status_text guards on
  # respond_to? and the write is currently inert (as it is for Akahu and Up). The strings
  # are still localized rather than hardcoded English, so they are correct the day the
  # column lands -- these assert the value passed, not a persisted attribute.
  test "walks the sync stages in order" do
    sync = Sync.create!(syncable: @item)
    @item.stubs(:import_latest_open_banking_io_data).returns({ success: true })

    seen = []
    @syncer.stubs(:update_status_text).with { |_s, text| seen << text; true }

    @syncer.perform_sync(sync)

    assert_equal [
      I18n.t("open_banking_io_item.syncer.importing_accounts"),
      I18n.t("open_banking_io_item.syncer.checking_configuration")
    ], seen
  end

  test "the sync stage text is localized rather than hardcoded English" do
    sync = Sync.create!(syncable: @item)
    @item.stubs(:import_latest_open_banking_io_data).returns({ success: true })

    seen = []
    @syncer.stubs(:update_status_text).with { |_s, text| seen << text; true }

    I18n.with_locale(:de) { @syncer.perform_sync(sync) }

    assert_equal I18n.t("open_banking_io_item.syncer.importing_accounts", locale: :de), seen.first
    assert_not_equal I18n.t("open_banking_io_item.syncer.importing_accounts", locale: :en), seen.first
  end

  test "flags pending_account_setup while any discovered account is unlinked" do
    @item.open_banking_io_accounts.create!(account_id: "acc-1", name: "Everyday", currency: "EUR")
    @item.stubs(:import_latest_open_banking_io_data).returns({ success: true })

    @syncer.perform_sync(Sync.create!(syncable: @item))
    assert @item.reload.pending_account_setup

    # ...and clears it once every account is linked.
    account = @item.family.accounts.create!(name: "Everyday", balance: 1, currency: "EUR", accountable: Depository.new)
    AccountProvider.create!(account: account, provider: @item.open_banking_io_accounts.first)

    @syncer.perform_sync(Sync.create!(syncable: @item))
    assert_not @item.reload.pending_account_setup
  end

  test "a failed import raises SyncError carrying the stage and reason" do
    sync = Sync.create!(syncable: @item)
    @item.stubs(:import_latest_open_banking_io_data).returns(
      { success: false, error: "Could not fetch open-banking.io accounts", accounts_failed: 2 }
    )

    error = assert_raises(OpenBankingIoItem::Syncer::SyncError) { @syncer.perform_sync(sync) }

    assert_match(/Could not fetch open-banking.io accounts/, error.message)
    assert_match(I18n.t("open_banking_io_item.errors.stages.import"), error.message)
  end

  # perform_post_sync must stay even though it is a no-op: Syncable#perform_post_sync
  # calls it unconditionally, so removing it raises NoMethodError mid-sync.
  test "responds to perform_post_sync" do
    assert_respond_to @syncer, :perform_post_sync
    assert_nil @syncer.perform_post_sync
  end
end
