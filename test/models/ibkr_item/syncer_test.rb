require "test_helper"

class IbkrItem::SyncerTest < ActiveSupport::TestCase
  fixtures :families, :ibkr_items

  setup do
    @ibkr_item = ibkr_items(:configured_item)
  end

  test "perform_sync records a single auth error when credentials are missing" do
    @ibkr_item.update!(token: nil)
    syncer = IbkrItem::Syncer.new(@ibkr_item)
    sync = @ibkr_item.syncs.create!

    error = assert_raises(Provider::IbkrFlex::ConfigurationError) do
      syncer.perform_sync(sync)
    end

    assert_equal "IBKR credentials are missing.", error.message
    assert_equal "requires_update", @ibkr_item.reload.status

    stats = sync.reload.sync_stats
    assert_equal 1, stats["total_errors"]
    assert_equal [ { "message" => "IBKR credentials are missing.", "category" => "auth_error" } ], stats["errors"]
  end
end
