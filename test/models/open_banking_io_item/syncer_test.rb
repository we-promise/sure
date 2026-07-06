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
end
