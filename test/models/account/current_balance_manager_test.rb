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

  test "judges a stale anchor immediately: preserves it as a waypoint when the ledger cannot explain the change" do
    day_one = Date.current
    manager = Account::CurrentBalanceManager.new(@linked_account)
    assert manager.set_current_balance(1000).success?

    original_id = @linked_account.valuations.current_anchor.first.id

    # Precondition, asserted rather than left to fixture luck: nothing can explain 1000 -> 2000
    assert_equal 0, @linked_account.entries.transactions.count

    travel_to day_one + 1.day do
      day_two_manager = Account::CurrentBalanceManager.new(@linked_account)

      # One promotion + one create: the old anchor is left behind as a waypoint and a
      # fresh anchor is created for today. Judged NOW, not on some later sync.
      assert_difference -> { @linked_account.entries.count } => 1,
                        -> { @linked_account.valuations.count } => 1 do
        result = day_two_manager.set_current_balance(2000)
        assert result.success?
        assert result.changes_made?
      end

      promoted = Valuation.find(original_id)
      assert_equal "reconciliation", promoted.kind
      assert_equal 1000, promoted.entry.amount
      assert_equal day_one, promoted.entry.date
      assert_equal Valuation.build_reconciliation_name(@linked_account.accountable_type), promoted.entry.name

      # Exactly one current_anchor: the freshly created one for today.
      assert_equal 1, @linked_account.valuations.current_anchor.count
      assert_equal 1, @linked_account.valuations.reconciliation.count

      assert_equal 2000, day_two_manager.current_balance
      assert_equal Date.current, day_two_manager.current_date
    end

    assert_equal 2000, @linked_account.balance
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

  # The bug this change exists for is not "a row has the wrong kind", it is "every day
  # before the waypoint is off by whatever posted after the mid-day reading". Assert that
  # directly: promoting day one's 1000 reading would pin day one's close at 1000 instead
  # of the true 600, inflating all earlier history by 400.
  test "an anchor that moves forward leaves the day's materialized balance at its true close" do
    day_one = Date.current
    assert Account::CurrentBalanceManager.new(@linked_account).set_current_balance(1000).success?

    travel_to day_one + 1.day do
      @linked_account.entries.create!(
        date: day_one,
        name: "Card payment",
        amount: 400,
        currency: "USD",
        entryable: Transaction.new
      )

      assert Account::CurrentBalanceManager.new(@linked_account).set_current_balance(600).success?

      Balance::Materializer.new(@linked_account, strategy: :reverse).materialize_balances

      day_one_balance = @linked_account.balances.find_by(date: day_one, currency: "USD")
      assert_equal 600, day_one_balance.balance
      assert_equal 1000, day_one_balance.start_cash_balance
    end
  end

  test "moves a stale anchor forward on a liability account using liability sign math" do
    card = accounts(:credit_card)
    card.update!(plaid_account: plaid_accounts(:one))
    assert card.linked?

    day_one = Date.current
    assert Account::CurrentBalanceManager.new(card).set_current_balance(500).success?
    stale_id = card.valuations.current_anchor.first.id

    travel_to day_one + 1.day do
      # Positive amount on a liability means "debt increased"
      card.entries.create!(
        date: day_one,
        name: "Purchase",
        amount: 30,
        currency: "USD",
        entryable: Transaction.new
      )

      assert Account::CurrentBalanceManager.new(card).set_current_balance(530).success?

      moved = Valuation.find(stale_id)
      assert_equal "current_anchor", moved.kind
      assert_empty card.valuations.reconciliation
      assert_equal 1, card.valuations.current_anchor.count
    end
  end

  test "moves a stale anchor forward across a multi-day gap" do
    day_one = Date.current
    assert Account::CurrentBalanceManager.new(@linked_account).set_current_balance(1000).success?
    stale_id = @linked_account.valuations.current_anchor.first.id

    travel_to day_one + 3.days do
      @linked_account.entries.create!(date: day_one, name: "Fee", amount: 20, currency: "USD", entryable: Transaction.new)
      @linked_account.entries.create!(date: day_one + 1.day, name: "Deposit", amount: -50, currency: "USD", entryable: Transaction.new)
      @linked_account.entries.create!(date: day_one + 2.days, name: "Coffee", amount: 10, currency: "USD", entryable: Transaction.new)

      assert Account::CurrentBalanceManager.new(@linked_account).set_current_balance(1020).success?

      moved = Valuation.find(stale_id)
      assert_equal "current_anchor", moved.kind
      assert_empty @linked_account.valuations.reconciliation
      assert_equal 1, @linked_account.valuations.current_anchor.count
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
