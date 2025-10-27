require "test_helper"

class SimplefinItemUiHelpersTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @item = SimplefinItem.create!(
      family: @family,
      name: "Test SimpleFin",
      access_url: "https://example.com/sfin"
    )
  end

  test "rate_limited_message returns friendly text when latest sync hints at rate limit" do
    # Use the error column to hint at rate limiting (Sync has no status_text column)
    Sync.create!(
      syncable: @item,
      status: :completed,
      error: "Please make fewer requests — only refreshed once every 24 hours"
    )

    msg = @item.rate_limited_message
    assert msg.present?, "expected a friendly rate limit message"
    assert_includes msg, "daily refresh limit"
  end

  test "rate_limited_message is nil when latest sync has no hints" do
    Sync.create!(
      syncable: @item,
      status: :completed,
      error: nil
    )
    assert_nil @item.rate_limited_message
  end

  test "skipped_accounts_count reads from latest sync stats" do
    Sync.create!(
      syncable: @item,
      status: :completed,
      sync_stats: { "skipped_accounts" => 3 }
    )
    assert_equal 3, @item.skipped_accounts_count
  end
end
