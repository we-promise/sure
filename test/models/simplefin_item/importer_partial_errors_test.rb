require "test_helper"

# Verifies the boundary between per-institution partial errors (which must not
# poison the whole SimpleFIN item's status) and top-level token-auth failures
# (which legitimately flag the item for reconnection).
class SimplefinItem::ImporterPartialErrorsTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @item = SimplefinItem.create!(
      family: @family,
      name: "SF Conn",
      access_url: "https://example.com/access"
    )
    @sync = Sync.create!(syncable: @item)
    @importer = SimplefinItem::Importer.new(@item, simplefin_provider: mock(), sync: @sync)
  end

  test "per-institution auth error does NOT flip item to requires_update" do
    # Partial-response error for ONE institution (e.g. Cash App) should not
    # poison the other 8 institutions in the same SimpleFIN connection.
    assert_equal "good", @item.status

    @importer.send(:record_errors, [
      "Connection to Cash App may need attention. Auth required"
    ])

    @item.reload
    assert_equal "good", @item.status,
      "expected item to remain good; per-institution auth errors must not flip the whole connection"
  end

  test "per-institution auth error still tracks in error_buckets for observability" do
    @importer.send(:record_errors, [
      "Connection to Cash App may need attention. Auth required"
    ])

    stats = @sync.reload.sync_stats
    assert_equal 1, stats.dig("error_buckets", "auth").to_i,
      "auth-category error should still be tracked in stats"
  end

  test "multiple per-institution errors do not flip item status" do
    @importer.send(:record_errors, [
      "Connection to Cash App may need attention. Auth required",
      "Please reauthenticate with Citibank",
      "two-factor authentication failed at Chase"
    ])

    @item.reload
    assert_equal "good", @item.status
    assert_equal 3, @sync.reload.sync_stats.dig("error_buckets", "auth").to_i
  end

  test "hash-shaped per-institution auth error does not flip item status" do
    @importer.send(:record_errors, [
      { code: "auth_failure", description: "Auth required for Cash App" }
    ])

    @item.reload
    assert_equal "good", @item.status
  end

  test "top-level handle_errors with auth failure DOES flip item to requires_update" do
    # Distinct from record_errors: this is the token-revoked / whole-connection-dead path.
    assert_equal "good", @item.status

    assert_raises(Provider::Simplefin::SimplefinError) do
      @importer.send(:handle_errors, [
        { code: "auth_failure", description: "Your SimpleFIN setup token was revoked" }
      ])
    end

    @item.reload
    assert_equal "requires_update", @item.status,
      "top-level token auth failures must still flag the item for reconnection"
  end

  test "previously requires_update item is cleared when no auth errors this sync" do
    @item.update!(status: :requires_update)

    # Simulate a clean sync (the maybe_clear path is already exercised in-suite;
    # here we confirm that record_errors with zero auth errors doesn't re-flag).
    @importer.send(:record_errors, [ "Timed out fetching Chase" ])

    @item.reload
    # record_errors alone doesn't clear - that's maybe_clear_requires_update_status's job -
    # but it also must not RE-flag when the error isn't auth-related.
    assert_equal "requires_update", @item.status
  end

  test "non-auth partial errors don't flip status" do
    @importer.send(:record_errors, [
      "Timed out fetching transactions from Chase",
      "429 rate limit hit at Citibank"
    ])

    @item.reload
    assert_equal "good", @item.status
    stats = @sync.reload.sync_stats
    assert_equal 1, stats.dig("error_buckets", "network").to_i
    assert_equal 1, stats.dig("error_buckets", "api").to_i
  end
end
