# frozen_string_literal: true

require "test_helper"

class Account::BalanceSyncWindowTest < ActiveSupport::TestCase
  setup do
    @account = accounts(:depository)
    @family = @account.family
  end

  test "returns explicit parent window when provided" do
    explicit = 10.days.ago.to_date

    window = Account::BalanceSyncWindow.for_account(
      @account,
      parent_window_start_date: explicit
    )

    assert_equal explicit, window
  end

  test "derives window from last_synced_at lookback when no explicit window" do
    last_synced = 2.days.ago
    lookback_start = last_synced.to_date - Account::BalanceSyncWindow::LOOKBACK
    floor = [ @account.opening_anchor_date, @account.start_date ].compact.max

    window = Account::BalanceSyncWindow.for_account(
      @account,
      last_synced_at: last_synced
    )

    assert_equal [ lookback_start, floor ].compact.max, window
  end

  test "uses earliest entry touched since parent sync" do
    parent_sync = @family.syncs.create!
    touched_date = 4.days.ago.to_date

    @account.entries.create!(
      name: "Recent import",
      date: touched_date,
      amount: -50,
      currency: "USD",
      entryable: Transaction.new,
      created_at: parent_sync.created_at + 1.minute,
      updated_at: parent_sync.created_at + 1.minute
    )

    window = Account::BalanceSyncWindow.for_account(@account, parent_sync: parent_sync)

    assert_equal touched_date, window
  end

  test "floors derived window at opening_anchor_date" do
    anchor_date = 3.days.ago.to_date
    @account.entries.create!(
      name: "Opening",
      date: anchor_date,
      amount: 1000,
      currency: "USD",
      entryable: Valuation.new(kind: "opening_anchor")
    )

    window = Account::BalanceSyncWindow.for_account(
      @account,
      last_synced_at: 1.day.ago,
      import_window_start_date: 30.days.ago.to_date
    )

    assert_equal anchor_date, window
  end

  test "returns nil when no window signals are available" do
    assert_nil Account::BalanceSyncWindow.for_account(@account)
  end
end
