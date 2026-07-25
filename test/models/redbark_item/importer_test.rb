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
      { "id" => "old_posted", "status" => "posted", "date" => "2026-05-01" }
    ]
    fresh = [ { "id" => "post_1", "status" => "posted", "date" => "2026-07-10" } ]

    merged = @importer.send(:merge_transactions, existing, fresh, window_start: Date.new(2026, 7, 1))
    ids = merged.map { |t| t["id"] }

    assert_includes ids, "post_1"
    assert_includes ids, "old_posted"
    assert_not_includes ids, "pend_1"
  end

  test "merge_transactions keeps pending rows dated before the refetched window" do
    existing = [ { "id" => "pend_old", "status" => "pending", "date" => "2026-06-15" } ]
    fresh = [ { "id" => "post_1", "status" => "posted", "date" => "2026-07-10" } ]

    merged = @importer.send(:merge_transactions, existing, fresh, window_start: Date.new(2026, 7, 1))

    assert_equal %w[pend_old post_1], merged.map { |t| t["id"] }.sort
  end
end
