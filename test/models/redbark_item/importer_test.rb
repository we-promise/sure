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

  test "import_transactions fetches from the stored sync_start_date when it's still within the lookback window" do
    redbark_account = redbark_accounts(:savings_account)
    redbark_account.update!(sync_start_date: 6.months.ago.to_date)

    assert_fetches_from(redbark_account, 6.months.ago.to_date)
  end

  test "import_transactions clamps an expired sync_start_date to the current max lookback" do
    redbark_account = redbark_accounts(:savings_account)
    # Bypass the model's own validation to simulate a date that was valid when
    # set but has since drifted outside the rolling window by the time a
    # delayed first fetch actually runs.
    redbark_account.update_column(:sync_start_date, (RedbarkAccount::MAX_SYNC_START_DATE_LOOKBACK_DAYS + 50).days.ago.to_date)

    assert_fetches_from(redbark_account, RedbarkAccount::MAX_SYNC_START_DATE_LOOKBACK_DAYS.days.ago.to_date)
  end

  test "import_transactions falls back to the default history window when there's no stored date" do
    redbark_account = redbark_accounts(:savings_account)
    redbark_account.update!(sync_start_date: nil)

    assert_fetches_from(redbark_account, RedbarkAccount::DEFAULT_INITIAL_HISTORY_DAYS.days.ago.to_date)
  end

  private

    # Asserts the date window import_transactions actually sends to Redbark,
    # rather than calling calculate_transaction_start_date directly -- that
    # private method's return value composing correctly with the rest of
    # import_transactions is exactly what's under test here.
    def assert_fetches_from(redbark_account, expected_start_date)
      provider = mock("redbark_provider")
      importer = RedbarkItem::Importer.new(@redbark_item, redbark_provider: provider)
      importer.stubs(:transactable_connection?).returns(true)
      importer.stubs(:connections_by_id).returns({})

      provider.expects(:get_transactions).with(
        connection_id: redbark_account.connection_id,
        account_id: redbark_account.redbark_account_id,
        start_date: expected_start_date,
        end_date: Date.current,
        include_pending: Rails.configuration.x.redbark.include_pending
      ).returns([])

      importer.send(:import_transactions, redbark_account)
    end
end
