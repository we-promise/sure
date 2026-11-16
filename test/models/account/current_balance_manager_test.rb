require "test_helper"

class Account::CurrentBalanceManagerTest < ActiveSupport::TestCase
  setup do
    @family = families(:empty)
    @linked_account = accounts(:connected)

    # Create account_provider to make the account actually linked
    # (The fixture has plaid_account but that's the legacy association)
    @linked_account.account_providers.find_or_create_by!(
      provider_type: "PlaidAccount",
      provider_id: plaid_accounts(:one).id
    )

    # The reuse of an explained anchor is gated on BALANCE_REUSE_EXPLAINED_ANCHOR (default off).
    Rails.configuration.x.balance.stubs(:reuse_explained_anchor).returns(true)
  end

  # -------------------------------------------------------------------------------------------------
  # Manual account current balance management
  #
  # Manual accounts do not manage `current_anchor` valuations and have "auto-update strategies" to set the current balance.
  # -------------------------------------------------------------------------------------------------

  test "when one or more reconciliations exist, append new reconciliation to represent the current balance" do
    account = @family.accounts.create!(
      name: "Test",
      balance: 1000,
      cash_balance: 1000,
      currency: "USD",
      accountable: Depository.new
    )

    # A reconciliation tells us that the user is tracking this account's value with balance-only updates
    account.entries.create!(
      date: 30.days.ago.to_date,
      name: "First manual recon valuation",
      amount: 1200,
      currency: "USD",
      entryable: Valuation.new(kind: "reconciliation")
    )

    manager = Account::CurrentBalanceManager.new(account)

    assert_equal 1, account.valuations.count

    # Here, we assume user is once again "overriding" the balance to 1400
    manager.set_current_balance(1400)

    today_valuation = account.entries.valuations.find_by(date: Date.current)

    assert_equal 2, account.valuations.count
    assert_equal 1400, today_valuation.amount

    assert_equal 1400, account.balance
  end

  test "all manual non cash accounts append reconciliations for current balance updates" do
    [ Property, Vehicle, OtherAsset, Loan, OtherLiability ].each do |account_type|
      account = @family.accounts.create!(
        name: "Test",
        balance: 1000,
        cash_balance: 1000,
        currency: "USD",
        accountable: account_type.new
      )

      manager = Account::CurrentBalanceManager.new(account)

      assert_equal 0, account.valuations.count

      manager.set_current_balance(1400)

      assert_equal 1, account.valuations.count

      today_valuation = account.entries.valuations.find_by(date: Date.current)

      assert_equal 1400, today_valuation.amount
      assert_equal 1400, account.balance
    end
  end

  # Scope: Depository, CreditCard only (i.e. all-cash accounts)
  #
  # If a user has an opening balance (valuation) for their manual *Depository* or *CreditCard* account and has 1+ transactions, the intent of
  # "updating current balance" typically means that their start balance is incorrect. We follow that user intent
  # by default and find the delta required, and update the opening balance so that the timeline reflects this current balance
  #
  # The purpose of this is so we're not cluttering up their timeline with "balance reconciliations" that reset the balance
  # on the current date. Our goal is to keep the timeline with as few "Valuations" as possible.
  #
  # If we ever build a UI that gives user options, this test expectation may require some updates, but for now this
  # is the least surprising outcome.
  test "when no reconciliations exist on cash accounts, adjust opening balance with delta until it gets us to the desired balance" do
    account = @family.accounts.create!(
      name: "Test",
      balance: 900, # the balance after opening valuation + transaction have "synced" (1000 - 100 = 900)
      cash_balance: 900,
      currency: "USD",
      accountable: Depository.new
    )

    account.entries.create!(
      date: 1.year.ago.to_date,
      name: "Test opening valuation",
      amount: 1000,
      currency: "USD",
      entryable: Valuation.new(kind: "opening_anchor")
    )

    account.entries.create!(
      date: 10.days.ago.to_date,
      name: "Test expense transaction",
      amount: 100,
      currency: "USD",
      entryable: Transaction.new
    )

    # What we're asserting here:
    # 1. User creates the account with an opening balance of 1000
    # 2. User creates a transaction of 100, which then reduces the balance to 900 (the current balance value on account above)
    # 3. User requests "current balance update" back to 1000, which was their intention
    # 4. We adjust the opening balance by the delta (100) to 1100, which is the new opening balance, so that the transaction
    #    of 100 reduces it down to 1000, which is the current balance they intended.
    assert_equal 1, account.valuations.count
    assert_equal 1, account.transactions.count

    # No new valuation is appended; we're just adjusting the opening valuation anchor
    assert_no_difference "account.entries.count" do
      manager = Account::CurrentBalanceManager.new(account)
      manager.set_current_balance(1000)
    end

    opening_valuation = account.valuations.find_by(kind: "opening_anchor")

    assert_equal 1100, opening_valuation.entry.amount
    assert_equal 1000, account.balance
  end

  # (SEE ABOVE TEST FOR MORE DETAILED EXPLANATION)
  # Same assertions as the test above, but Credit Card accounts are liabilities, which means expenses increase balance; not decrease
  test "when no reconciliations exist on credit card accounts, adjust opening balance with delta until it gets us to the desired balance" do
    account = @family.accounts.create!(
      name: "Test",
      balance: 1100, # the balance after opening valuation + transaction have "synced" (1000 + 100 = 1100) (expenses increase balance)
      cash_balance: 1100,
      currency: "USD",
      accountable: CreditCard.new
    )

    account.entries.create!(
      date: 1.year.ago.to_date,
      name: "Test opening valuation",
      amount: 1000,
      currency: "USD",
      entryable: Valuation.new(kind: "opening_anchor")
    )

    account.entries.create!(
      date: 10.days.ago.to_date,
      name: "Test expense transaction",
      amount: 100,
      currency: "USD",
      entryable: Transaction.new
    )

    assert_equal 1, account.valuations.count
    assert_equal 1, account.transactions.count

    assert_no_difference "account.entries.count" do
      manager = Account::CurrentBalanceManager.new(account)
      manager.set_current_balance(1000)
    end

    opening_valuation = account.valuations.find_by(kind: "opening_anchor")

    assert_equal 900, opening_valuation.entry.amount
    assert_equal 1000, account.balance
  end

  # -------------------------------------------------------------------------------------------------
  # Linked account current balance management
  #
  # Linked accounts manage "current balance" via the special `current_anchor` valuation.
  # This is NOT a user-facing feature, and is primarily used in "processors" while syncing
  # linked account data (e.g. via Plaid)
  # -------------------------------------------------------------------------------------------------

  test "when no existing anchor for linked account, creates new anchor" do
    manager = Account::CurrentBalanceManager.new(@linked_account)

    assert_difference -> { @linked_account.entries.count } => 1,
                     -> { @linked_account.valuations.count } => 1 do
      result = manager.set_current_balance(1000)

      assert result.success?
      assert result.changes_made?
      assert_nil result.error
    end

    current_anchor = @linked_account.valuations.current_anchor.first
    assert_not_nil current_anchor
    assert_equal 1000, current_anchor.entry.amount
    assert_equal "current_anchor", current_anchor.kind

    entry = current_anchor.entry
    assert_equal 1000, entry.amount
    assert_equal Date.current, entry.date
    assert_equal "Current balance", entry.name  # Depository type returns "Current balance"

    assert_equal 1000, @linked_account.balance
  end
  # A provider whose figures come from a statement knows the day they describe,
  # which is not always today.
  test "anchors a linked account balance on the date it is given" do
    manager = Account::CurrentBalanceManager.new(@linked_account)
    statement_date = Date.current - 1.day

    result = manager.set_current_balance(1000, date: statement_date)
    assert result.success?

    entry = @linked_account.valuations.current_anchor.first.entry
    assert_equal statement_date, entry.date
    assert_equal 1000, entry.amount
  end

  # A statement older than the anchor is a correction to a day gone by. It is
  # recorded on that day, and the newer anchor -- with the newer figure, and the
  # balance the account reports -- is left alone. This also covers an account
  # whose anchor is still dated by the day it was written: that anchor keeps its
  # date until a statement catches up with it, and is corrected in place then.
  test "a statement older than the anchor is recorded on its own date" do
    manager = Account::CurrentBalanceManager.new(@linked_account)
    manager.set_current_balance(2000)
    anchor_id = @linked_account.valuations.current_anchor.first.id

    manager.set_current_balance(1000, date: Date.current - 1.day)

    anchor = @linked_account.valuations.current_anchor.first
    assert_equal anchor_id, anchor.id, "the newer anchor must survive"
    assert_equal Date.current, anchor.entry.date
    assert_equal 2000, anchor.entry.amount
    assert_equal 2000, @linked_account.reload.balance, "the cached balance must not go backwards"

    older = @linked_account.entries.valuations.find_by(date: Date.current - 1.day)
    assert_not_nil older, "the older statement is kept where it belongs"
    assert_equal 1000, older.amount
  end

  # Two statements carrying the same date are one anchor, not an anchor and a
  # reconciliation sitting on the same day.
  test "a repeated statement date updates the anchor in place" do
    manager = Account::CurrentBalanceManager.new(@linked_account)
    statement_date = Date.current - 1.day
    manager.set_current_balance(1000, date: statement_date)

    travel_to Date.current + 1.day do
      assert_no_difference -> { @linked_account.valuations.count } do
        manager.set_current_balance(1500, date: statement_date)
      end
    end

    assert_equal 1, @linked_account.valuations.current_anchor.count
    entry = @linked_account.valuations.current_anchor.first.entry
    assert_equal statement_date, entry.date
    assert_equal 1500, entry.amount
  end

  test "moves a stale anchor forward when the imported ledger explains the balance change" do
    day_one = Date.current
    manager = Account::CurrentBalanceManager.new(@linked_account)
    assert manager.set_current_balance(1000).success?
    stale_id = @linked_account.valuations.current_anchor.first.id

    travel_to day_one + 1.day do
      # Processors now import transactions BEFORE anchoring, so day one's entries are
      # already persisted by the time set_current_balance judges the old anchor.
      @linked_account.entries.create!(
        date: day_one,
        name: "Card payment",
        amount: 400,
        currency: "USD",
        entryable: Transaction.new
      )

      day_two_manager = Account::CurrentBalanceManager.new(@linked_account)

      # The anchor just moves forward in place: no destroy, no create. Net row delta
      # is ZERO.
      assert_no_difference -> { @linked_account.entries.count } do
        assert_no_difference -> { @linked_account.valuations.count } do
          assert day_two_manager.set_current_balance(600).success?
        end
      end

      moved = Valuation.find(stale_id)
      assert_equal "current_anchor", moved.kind
      assert_equal 600, moved.entry.amount
      assert_equal Date.current, moved.entry.date
      assert_equal 1, @linked_account.valuations.current_anchor.count
      assert_empty @linked_account.valuations.reconciliation
    end
  end

  # With BALANCE_REUSE_EXPLAINED_ANCHOR off (the default), the ledger is never consulted and
  # every stale anchor rotates into a reconciliation waypoint, as it did before this gate.
  test "preserves a stale anchor as a waypoint when the explained-anchor reuse flag is off" do
    Rails.configuration.x.balance.stubs(:reuse_explained_anchor).returns(false)

    day_one = Date.current
    assert Account::CurrentBalanceManager.new(@linked_account).set_current_balance(1000).success?
    stale_id = @linked_account.valuations.current_anchor.first.id

    travel_to day_one + 1.day do
      @linked_account.entries.create!(
        date: day_one,
        name: "Card payment",
        amount: 400,
        currency: "USD",
        entryable: Transaction.new
      )

      assert Account::CurrentBalanceManager.new(@linked_account).set_current_balance(600).success?

      preserved = Valuation.find(stale_id)
      assert_equal "reconciliation", preserved.kind
      assert_equal 1000, preserved.entry.amount
      assert_equal day_one, preserved.entry.date

      anchors = @linked_account.valuations.current_anchor
      assert_equal 1, anchors.count
      assert_equal 600, anchors.first.entry.amount
      assert_equal Date.current, anchors.first.entry.date
    end
  end

  # An anchor moved forward in place carries the flows dated on its new date inside its own
  # amount. Re-summing that date on the next sync counts them twice, makes the move look
  # unexplained, and freezes a mid-day reading as a waypoint - the #1492 / #1484 corruption
  # this change exists to remove. Needs three syncs to reach; no other test goes that far.
  test "an anchor already moved forward in place is not double counted on the next sync" do
    day_one = Date.current
    day_two = day_one + 1.day
    day_three = day_one + 2.days

    # Day one, 02:22: the provider reports 1000 and nothing has posted yet.
    travel_to Time.zone.parse("#{day_one} 02:22") do
      assert Account::CurrentBalanceManager.new(@linked_account).set_current_balance(1000).success?
    end

    anchor_id = @linked_account.valuations.current_anchor.first.id

    # Day two, 02:22: yesterday's 400 arrives in today's batch. The ledger explains
    # 1000 -> 600, so the anchor moves forward IN PLACE to day two / 600.
    travel_to Time.zone.parse("#{day_two} 02:22") do
      @linked_account.entries.create!(
        date: day_one,
        name: "Day 1 spend",
        amount: 400,
        currency: "USD",
        entryable: Transaction.new
      )

      assert Account::CurrentBalanceManager.new(@linked_account).set_current_balance(600).success?
    end

    # Precondition for the bug, asserted rather than assumed.
    assert_equal "current_anchor", Valuation.find(anchor_id).kind
    assert_equal day_two, Valuation.find(anchor_id).entry.date

    # Day two, 14:00: a second cycle the same day. 100 posts, dated to day two, and the
    # reading drops to 500. Same-day update, so the anchor's amount now BAKES IN that 100.
    travel_to Time.zone.parse("#{day_two} 14:00") do
      @linked_account.entries.create!(
        date: day_two,
        name: "Day 2 spend (early)",
        amount: 100,
        currency: "USD",
        entryable: Transaction.new
      )

      assert Account::CurrentBalanceManager.new(@linked_account).set_current_balance(500).success?
    end

    assert_equal 500, Valuation.find(anchor_id).entry.amount
    assert_equal day_two, Valuation.find(anchor_id).entry.date

    # Day three, 02:22: the 50 that posted after yesterday's last reading arrives, dated
    # to day two. True day-two close = 1000 - 400 - 100 - 50 = 450, and 450 is exactly what
    # the provider now reports. The only flow NOT already inside the anchor's 500 is that 50,
    # so the ledger fully explains 500 -> 450 and the anchor should just move forward again.
    travel_to Time.zone.parse("#{day_three} 02:22") do
      @linked_account.entries.create!(
        date: day_two,
        name: "Day 2 spend (late)",
        amount: 50,
        currency: "USD",
        entryable: Transaction.new
      )

      assert Account::CurrentBalanceManager.new(@linked_account).set_current_balance(450).success?

      moved = Valuation.find(anchor_id)
      assert_equal "current_anchor", moved.kind,
        "the day-two 100 is already inside the anchor's 500; re-summing it makes an explained " \
        "move look unexplained and freezes a mid-day reading as a waypoint"
      assert_empty @linked_account.valuations.reconciliation
      assert_equal 1, @linked_account.valuations.current_anchor.count
      assert_equal day_three, moved.entry.date
      assert_equal 450, moved.entry.amount
    end
  end

  test "preserves a stale anchor when the explaining window mixes currencies" do
    day_one = Date.current
    assert Account::CurrentBalanceManager.new(@linked_account).set_current_balance(1000).success?
    stale_id = @linked_account.valuations.current_anchor.first.id

    travel_to day_one + 1.day do
      @linked_account.entries.create!(
        date: day_one,
        name: "Foreign card payment",
        amount: 400,
        currency: "EUR",
        entryable: Transaction.new
      )

      assert Account::CurrentBalanceManager.new(@linked_account).set_current_balance(600).success?

      assert_equal "reconciliation", Valuation.find(stale_id).kind
      assert_equal 1, @linked_account.valuations.current_anchor.count
    end
  end

  test "does not move a stale anchor forward on an investment account" do
    investment = accounts(:investment)
    investment.update!(plaid_account: plaid_accounts(:one))
    assert investment.linked?

    day_one = Date.current
    assert Account::CurrentBalanceManager.new(investment).set_current_balance(1000).success?
    stale_id = investment.valuations.current_anchor.first.id

    travel_to day_one + 1.day do
      investment.entries.create!(date: day_one, name: "Withdrawal", amount: 400, currency: "USD", entryable: Transaction.new)

      assert Account::CurrentBalanceManager.new(investment).set_current_balance(600).success?

      assert_equal "reconciliation", Valuation.find(stale_id).kind
      assert_equal 1, investment.valuations.current_anchor.count
    end
  end

  test "does not preserve same-day anchor as reconciliation" do
    manager = Account::CurrentBalanceManager.new(@linked_account)

    # Create initial anchor
    result = manager.set_current_balance(1000)
    assert result.success?

    current_anchor = @linked_account.valuations.current_anchor.first
    original_id = current_anchor.id

    # Try to set the same value on the same date
    assert_no_difference -> { @linked_account.entries.count } do
      result = manager.set_current_balance(1000)
      assert result.success?
      assert_not result.changes_made?
    end

    # Update with different value on the same day
    assert_no_difference -> { @linked_account.entries.count } do
      assert_no_difference -> { @linked_account.valuations.count } do
        result = manager.set_current_balance(1500)
        assert result.success?
        assert result.changes_made?
      end
    end

    current_anchor.reload
    assert_equal original_id, current_anchor.id
    assert_equal 1500, current_anchor.entry.amount
    assert_equal "current_anchor", current_anchor.kind
    assert_equal Date.current, current_anchor.entry.date

    assert_equal 1500, @linked_account.balance
  end

  test "current_balance returns balance from current anchor" do
    manager = Account::CurrentBalanceManager.new(@linked_account)

    # Create a current anchor
    manager.set_current_balance(1500)

    # Should return the anchor's balance
    assert_equal 1500, manager.current_balance

    # Update the anchor
    manager.set_current_balance(2500)

    # Should return the updated balance
    assert_equal 2500, manager.current_balance

    assert_equal 2500, @linked_account.balance
  end

  test "current_balance falls back to account balance when no anchor exists" do
    manager = Account::CurrentBalanceManager.new(@linked_account)

    # When no current anchor exists, should fall back to account.balance
    assert_equal @linked_account.balance, manager.current_balance

    assert_equal @linked_account.balance, @linked_account.balance
  end
end
