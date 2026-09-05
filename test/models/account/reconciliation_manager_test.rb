require "test_helper"

class Account::ReconciliationManagerTest < ActiveSupport::TestCase
  include BalanceTestHelper

  setup do
    @account = accounts(:investment)
    @manager = Account::ReconciliationManager.new(@account)
  end

  test "new reconciliation" do
    create_balance(account: @account, date: Date.current, balance: 1000, cash_balance: 500)

    result = @manager.reconcile_balance(balance: 1200, date: Date.current)

    assert_equal 1200, result.new_balance
    assert_equal 700, result.new_cash_balance # Non cash stays the same since user is valuing the entire account balance
    assert_equal 1000, result.old_balance
    assert_equal 500, result.old_cash_balance
    assert_equal true, result.success?
  end

  test "updates existing reconciliation without date change" do
    create_balance(account: @account, date: Date.current, balance: 1000, cash_balance: 500)

    # Existing reconciliation entry
    existing_entry = @account.entries.create!(name: "Test", amount: 1000, date: Date.current, entryable: Valuation.new(kind: "reconciliation"), currency: @account.currency)

    result = @manager.reconcile_balance(balance: 1200, date: Date.current, existing_valuation_entry: existing_entry)

    assert_equal 1200, result.new_balance
    assert_equal 700, result.new_cash_balance # Non cash stays the same since user is valuing the entire account balance
    assert_equal 1000, result.old_balance
    assert_equal 500, result.old_cash_balance
    assert_equal true, result.success?
  end

  test "updates existing reconciliation with date and amount change" do
    create_balance(account: @account, date: 5.days.ago, balance: 1000, cash_balance: 500)
    create_balance(account: @account, date: Date.current, balance: 1200, cash_balance: 700)

    # Existing reconciliation entry (5 days ago)
    existing_entry = @account.entries.create!(name: "Test", amount: 1000, date: 5.days.ago, entryable: Valuation.new(kind: "reconciliation"), currency: @account.currency)

    # Should update and change date for existing entry; not create a new one
    assert_no_difference "Valuation.count" do
      # "Update valuation from 5 days ago to today, set balance from 1000 to 1500"
      result = @manager.reconcile_balance(balance: 1500, date: Date.current, existing_valuation_entry: existing_entry)

      assert_equal true, result.success?

      # Reconciliation
      assert_equal 1500, result.new_balance # Equal to new valuation amount
      assert_equal 1000, result.new_cash_balance # Get non-cash balance today (1200 - 700 = 500). Then subtract this from new valuation (1500 - 500 = 1000)

      # Prior valuation
      assert_equal 1000, result.old_balance # This is the balance from the old valuation, NOT the date we're reconciling to
      assert_equal 500, result.old_cash_balance
    end
  end

  test "handles date conflicts" do
    create_balance(account: @account, date: Date.current, balance: 1000, cash_balance: 1000)

    # Existing reconciliation entry
    @account.entries.create!(
      name: "Test",
      amount: 1000,
      date: Date.current,
      entryable: Valuation.new(kind: "reconciliation"),
      currency: @account.currency
    )

    # Doesn't pass existing_valuation_entry, but reconciliation manager should recognize its the same date and update the existing entry
    assert_no_difference "Valuation.count" do
      result = @manager.reconcile_balance(balance: 1200, date: Date.current)

      assert result.success?
      assert_equal 1200, result.new_balance
    end
  end

  test "handles a genuine concurrent double-submit without raising or duplicating" do
    create_balance(account: @account, date: Date.current, balance: 1000, cash_balance: 500)

    # Simulates the race: another request reconciling the same account+date
    # wins and commits its INSERT in the window between our own
    # find_existing_valuation_for_date lookup (which therefore still sees
    # nothing, hence the first `nil`) and our #save! (which then hits the
    # real partial unique index on entries(account_id, date) for valuations
    # and raises RecordNotUnique, exactly like the DB would under real
    # concurrent requests). The rescue then re-runs the same lookup, this
    # time finding the winner, and retries against it.
    winning_entry = @account.entries.create!(
      name: "Test", amount: 1000, date: Date.current,
      entryable: Valuation.new(kind: "reconciliation"), currency: @account.currency
    )
    @manager.stubs(:find_existing_valuation_for_date).returns(nil, winning_entry)
    Entry.any_instance.stubs(:save!)
      .raises(ActiveRecord::RecordNotUnique.new("duplicate key value violates unique constraint"))
      .then.returns(true)

    assert_no_difference "Valuation.count" do
      result = @manager.reconcile_balance(balance: 1200, date: Date.current)

      assert result.success?
      assert_equal 1200, result.new_balance
    end
  end

  test "recovers when the winner is caught by the model-level date-uniqueness validation instead of the DB index" do
    create_balance(account: @account, date: Date.current, balance: 1000, cash_balance: 500)

    # A different timing than the DB-unique-index test above: here the
    # winning valuation is already committed and visible by the time our
    # own save runs its validations, so Entry's own date-uniqueness
    # validation (validates :date, uniqueness: ..., if: -> { valuation? })
    # catches it first and raises RecordInvalid - never reaching the
    # database at all, so RecordNotUnique alone wouldn't have covered this.
    winning_entry = @account.entries.create!(
      name: "Test", amount: 1000, date: Date.current,
      entryable: Valuation.new(kind: "reconciliation"), currency: @account.currency
    )
    @manager.stubs(:find_existing_valuation_for_date).returns(nil, winning_entry)

    assert_no_difference "Valuation.count" do
      result = @manager.reconcile_balance(balance: 1200, date: Date.current)

      assert result.success?
      assert_equal 1200, result.new_balance
    end
  end

  test "recovers from a genuine unique-index conflict even inside an outer transaction" do
    create_balance(account: @account, date: Date.current, balance: 1000, cash_balance: 500)

    # Reproduces a real gap a reviewer found: a caller (e.g.
    # Api::V1::ValuationsController#create) wraps reconcile_balance in its
    # own outer transaction. Without `requires_new: true` on the internal
    # save, a real unique-index violation here aborts that whole outer
    # PostgreSQL transaction, and the rescue's own retry query then raises
    # PG::InFailedSqlTransaction instead of finding the winning row - a real
    # DB-level violation, not a stub, is needed to prove this.
    ActiveRecord::Base.transaction do
      winning_entry = @account.entries.create!(
        name: "Test", amount: 1000, date: Date.current,
        entryable: Valuation.new(kind: "reconciliation"), currency: @account.currency
      )
      # Force the manager to attempt a fresh INSERT despite a valuation
      # already existing for this date, so its own #save! is the one that
      # collides with the real unique index (rather than updating in place).
      @manager.stubs(:find_existing_valuation_for_date).returns(nil, winning_entry)
      # Entry's own model-level uniqueness validation (see Entry#validates
      # :date, uniqueness: ...) would otherwise catch this same conflict
      # first as an ordinary ActiveRecord::RecordInvalid, before the save
      # ever reaches the database - skip it so the save actually reaches
      # PostgreSQL and collides with the real unique index, which is what
      # this test needs to reproduce the transaction-abort behavior.
      Entry.any_instance.stubs(:valid?).returns(true)

      result = @manager.reconcile_balance(balance: 1200, date: Date.current)

      assert result.success?
      assert_equal 1200, result.new_balance
    end
  end

  test "a RecordNotUnique with no matching valuation is reported, not silently swallowed" do
    create_balance(account: @account, date: Date.current, balance: 1000, cash_balance: 500)

    # Defensive-branch coverage: if the unique index ever rejects an insert
    # for a reason other than "another request reconciling this exact
    # account+date already won," we must not pretend it succeeded.
    @manager.stubs(:find_existing_valuation_for_date).returns(nil)
    Entry.any_instance.stubs(:save!).raises(ActiveRecord::RecordNotUnique.new("duplicate key value violates unique constraint"))

    assert_no_difference "Valuation.count" do
      result = @manager.reconcile_balance(balance: 1200, date: Date.current)

      assert_not result.success?
      # The raw Postgres exception text (which includes the internal index
      # name) must never reach the user - a friendly message is substituted.
      assert_equal I18n.t("valuations.errors.duplicate_date"), result.error_message
      assert_no_match "duplicate key value violates unique constraint", result.error_message
    end
  end

  test "dry run does not persist account" do
    create_balance(account: @account, date: Date.current, balance: 1000, cash_balance: 500)

    assert_no_difference "Valuation.count" do
      @manager.reconcile_balance(balance: 1200, date: Date.current, dry_run: true)
    end

    assert_difference "Valuation.count", 1 do
      @manager.reconcile_balance(balance: 1200, date: Date.current)
    end
  end

  test "reconciliation matches an open manual_save pledge by contribution delta" do
    account = accounts(:depository)
    manager = Account::ReconciliationManager.new(account)
    create_balance(account: account, date: Date.current, balance: 2000, cash_balance: 2000)

    pledge = goal_pledges(:open_transfer).goal.goal_pledges.create!(
      account: account,
      amount: 150,
      currency: "USD",
      kind: "manual_save"
    )

    result = manager.reconcile_balance(balance: 2150, date: Date.current)

    assert result.success?
    assert pledge.reload.status_matched?
  end

  test "reconciliation to the same balance leaves manual_save pledges open" do
    account = accounts(:depository)
    manager = Account::ReconciliationManager.new(account)
    create_balance(account: account, date: Date.current, balance: 2000, cash_balance: 2000)

    pledge = goal_pledges(:open_transfer).goal.goal_pledges.create!(
      account: account,
      amount: 150,
      currency: "USD",
      kind: "manual_save"
    )

    result = manager.reconcile_balance(balance: 2000, date: Date.current)

    assert result.success?
    assert_not pledge.reload.status_matched?
  end

  test "second same-day reconcile derives its delta from the valuation it updates, not the stale balance row" do
    account = accounts(:depository)
    manager = Account::ReconciliationManager.new(account)
    create_balance(account: account, date: Date.current, balance: 2000, cash_balance: 2000)

    goal = goal_pledges(:open_transfer).goal
    first_pledge = goal.goal_pledges.create!(
      account: account,
      amount: 150,
      currency: "USD",
      kind: "manual_save"
    )

    assert manager.reconcile_balance(balance: 2150, date: Date.current).success?
    assert first_pledge.reload.status_matched?

    # The post-reconcile balance sync is async and hasn't run, so the
    # balances row still says $2,000. The second save of $150 (2150 → 2300)
    # must not be read as a $300 contribution off that stale row — that
    # would wrongly close the larger pledge, and a wrong match never
    # self-heals.
    oversized_pledge = goal.goal_pledges.create!(
      account: account,
      amount: 300,
      currency: "USD",
      kind: "manual_save"
    )
    second_pledge = goal.goal_pledges.create!(
      account: account,
      amount: 150,
      currency: "USD",
      kind: "manual_save"
    )

    assert manager.reconcile_balance(balance: 2300, date: Date.current).success?

    assert_not oversized_pledge.reload.status_matched?
    assert second_pledge.reload.status_matched?
  end
end
