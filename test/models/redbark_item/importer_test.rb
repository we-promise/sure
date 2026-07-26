require "test_helper"

class RedbarkItem::ImporterTest < ActiveSupport::TestCase
  setup do
    @redbark_item = redbark_items(:one)
    @importer = RedbarkItem::Importer.new(@redbark_item, redbark_provider: nil)
  end

  test "merge_transactions keeps posted rows and refreshes by id" do
    existing = [ { "id" => "t1", "status" => "posted", "date" => "2026-07-01", "amount" => "-10.00" } ]
    fresh = [ { "id" => "t1", "status" => "posted", "date" => "2026-07-01", "amount" => "-12.00" } ]

    merged = @importer.send(:merge_transactions, existing, fresh, window_start: Date.new(2026, 6, 1))

    assert_equal 1, merged.size
    assert_equal "-12.00", merged.first["amount"]
  end

  test "merge_transactions prunes pending rows missing from the refetched window" do
    existing = [
      { "id" => "pend_1", "status" => "pending", "date" => "2026-07-10" },
      { "id" => "kept_posted", "status" => "posted", "date" => "2026-07-05" }
    ]
    fresh = [ { "id" => "post_1", "status" => "posted", "date" => "2026-07-10" } ]

    merged = @importer.send(:merge_transactions, existing, fresh, window_start: Date.new(2026, 7, 1))
    ids = merged.map { |t| t["id"] }

    assert_includes ids, "post_1"
    assert_includes ids, "kept_posted"
    assert_not_includes ids, "pend_1"
  end

  test "merge_transactions drops rows dated before the fetch window" do
    existing = [
      { "id" => "old_posted", "status" => "posted", "date" => "2026-05-01" },
      { "id" => "old_pending", "status" => "pending", "date" => "2026-06-15" },
      { "id" => "undated", "status" => "posted" }
    ]
    fresh = [ { "id" => "post_1", "status" => "posted", "date" => "2026-07-10" } ]

    merged = @importer.send(:merge_transactions, existing, fresh, window_start: Date.new(2026, 7, 1))

    assert_equal %w[post_1 undated], merged.map { |t| t["id"] }.sort
  end

  test "merge_transactions keeps everything when no window is given" do
    existing = [ { "id" => "old_posted", "status" => "posted", "date" => "2026-05-01" } ]
    fresh = [ { "id" => "post_1", "status" => "posted", "date" => "2026-07-10" } ]

    merged = @importer.send(:merge_transactions, existing, fresh, window_start: nil)

    assert_equal %w[old_posted post_1], merged.map { |t| t["id"] }.sort
  end
end
