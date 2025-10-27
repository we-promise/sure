require "test_helper"

class SimplefinItemSyncerTest < ActiveSupport::TestCase
  class FakeSimplefinProvider
    def initialize(payload)
      @payload = payload
    end

    def get_accounts(_access_url, start_date: nil, end_date: nil, pending: nil)
      @payload.deep_symbolize_keys
    end
  end

  setup do
    @family = families(:dylan_family)
    @item = SimplefinItem.create!(
      family: @family,
      name: "Test SimpleFin",
      access_url: "https://example.com/sfin"
    )
  end

  test "syncer includes skipped_accounts in sync_stats when importer skips" do
    payload = {
      accounts: [
        { id: "acct_err", error: "Bridge error" }
      ]
    }
    fake = FakeSimplefinProvider.new(payload)

    # Stub the provider used by the importer
    @item.stubs(:simplefin_provider).returns(fake)

    sync = Sync.create!(syncable: @item)

    # Directly invoke the SimplefinItem::Syncer
    SimplefinItem::Syncer.new(@item).perform_sync(sync)

    assert sync.sync_stats.present?, "expected sync_stats to be set"
    assert_equal 1, sync.sync_stats["skipped_accounts"].to_i
  end
end
