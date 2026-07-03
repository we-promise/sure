require "test_helper"

class SyncableTest < ActiveSupport::TestCase
  setup do
    @account = accounts(:depository)
    @account.syncs.delete_all
  end

  test "syncing? is true when a recent incomplete sync exists" do
    @account.syncs.create!(status: "pending")

    assert @account.syncing?
  end

  test "syncing? is false when syncs are completed or too old" do
    @account.syncs.create!(status: "completed", completed_at: Time.current)
    stale = @account.syncs.create!(status: "pending")
    stale.update_column(:created_at, (Sync::VISIBLE_FOR + 1.minute).ago)

    refute @account.syncing?
  end

  test "syncing? uses the preloaded syncs collection without new queries" do
    @account.syncs.create!(status: "pending")
    loaded_account = Account.includes(:syncs).find(@account.id)

    result = nil
    queries = capture_sql_queries do
      result = loaded_account.syncing?
    end

    assert result
    assert_empty queries, "expected no queries with preloaded syncs, got: #{queries}"
  end

  test "syncing? on preloaded collection matches the visible scope semantics" do
    @account.syncs.create!(status: "completed", completed_at: Time.current)
    stale = @account.syncs.create!(status: "pending")
    stale.update_column(:created_at, (Sync::VISIBLE_FOR + 1.minute).ago)

    loaded_account = Account.includes(:syncs).find(@account.id)

    refute loaded_account.syncing?
  end
end
