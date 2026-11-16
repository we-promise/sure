require "test_helper"

class ExchangeRate::BalanceRefreshTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    ExchangeRate.delete_all
    @family = families(:empty)
    @account = usd_account
    @date = 10.days.ago.to_date
  end

  # The bug end to end: a sync drops an entry it has no rate for, the rate
  # arrives later, and the balance has to come back with the entry in it.
  test "a rate stored after a sync dropped an entry rebuilds the balance with it" do
    eur_deposit(account: @account, date: @date, amount: 100)
    Balance::Materializer.new(@account, strategy: :forward).materialize_balances
    before = closing_balance(@account)

    ExchangeRate.create!(from_currency: "EUR", to_currency: "USD", date: @date, rate: 1.1)
    perform_enqueued_jobs do
      ExchangeRate::BalanceRefresh.schedule([ { from: "EUR", to: "USD", date: @date, stored_at: Time.current } ])
    end

    assert_equal before + 110, closing_balance(@account), "the 100 EUR deposit is now in the balance at 1.1"
  end

  test "an account whose entry converts at a changed rate is synced from that entry's date" do
    eur_deposit(account: @account, date: @date + 2.days, amount: 100)
    eur_deposit(account: @account, date: @date + 1.day, amount: 50)
    ExchangeRate.create!(from_currency: "EUR", to_currency: "USD", date: @date, rate: 1.1)

    ExchangeRate::BalanceRefresh.schedule([ { from: "EUR", to: "USD", date: @date, stored_at: Time.current } ])

    assert_equal [ @date + 1.day ], @account.syncs.pluck(:window_start_date)
  end

  # Only entries that had no usable rate before the write: an entry with an
  # older rate in its lookback (the daily case, a rate following yesterday's)
  # was converted, and a new rate there changes nothing.
  test "accounts whose entries do not convert at a changed rate are left alone" do
    later_rate = usd_account
    eur_deposit(account: later_rate, date: @date + 2.days, amount: 100)
    ExchangeRate.create!(from_currency: "EUR", to_currency: "USD", date: @date + 1.day, rate: 1.2)

    out_of_reach = usd_account
    eur_deposit(account: out_of_reach, date: @date + ExchangeRate::Provided::NEAREST_RATE_LOOKBACK_DAYS + 1, amount: 100)

    other_pair = usd_account
    other_pair.entries.create!(name: "GBP", date: @date, amount: -100, currency: "GBP", entryable: Transaction.new)

    same_currency = @family.accounts.create!(name: "EUR", balance: 0, currency: "EUR", accountable: Depository.new)
    eur_deposit(account: same_currency, date: @date, amount: 100)

    ExchangeRate.create!(from_currency: "EUR", to_currency: "USD", date: @date, rate: 1.1)
    eur_deposit(account: @account, date: @date, amount: 100)

    ExchangeRate::BalanceRefresh.schedule([ { from: "EUR", to: "USD", date: @date, stored_at: Time.current } ])

    assert_equal 1, @account.syncs.count, "precondition: the account that did use the rate is synced"
    [ later_rate, out_of_reach, other_pair, same_currency ].each do |account|
      assert_equal 0, account.syncs.count, "#{account.name} converts no differently"
    end
  end

  # Two writes stored apart, each queuing its own refresh before either runs:
  # the rate the other write stored was not there when this one's balance
  # went without, so it cannot stand in for one that was.
  test "rates stored by separate writes do not cancel each other's refresh" do
    eur_deposit(account: @account, date: @date + 1.day, amount: 100)
    first = ExchangeRate.create!(from_currency: "EUR", to_currency: "USD", date: @date, rate: 1.1)
    travel 1.second
    second = ExchangeRate.create!(from_currency: "EUR", to_currency: "USD", date: @date + 1.day, rate: 1.1)

    ExchangeRate::BalanceRefresh.schedule([ { from: "EUR", to: "USD", date: first.date, stored_at: first.created_at } ])
    ExchangeRate::BalanceRefresh.schedule([ { from: "EUR", to: "USD", date: second.date, stored_at: second.created_at } ])

    assert_operator @account.syncs.count, :>=, 1, "the entry that had no rate is rebuilt by one of the two refreshes"
  end

  # Several pairs at once: the account syncs from the earliest date any of
  # them affects.
  test "an account affected through several pairs is synced from the earliest date" do
    eur_deposit(account: @account, date: @date + 2.days, amount: 100)
    @account.entries.create!(name: "GBP", date: @date, amount: -50, currency: "GBP", entryable: Transaction.new)
    ExchangeRate.create!(from_currency: "EUR", to_currency: "USD", date: @date + 2.days, rate: 1.1)
    ExchangeRate.create!(from_currency: "GBP", to_currency: "USD", date: @date, rate: 1.3)

    ExchangeRate::BalanceRefresh.schedule([
      { from: "EUR", to: "USD", date: @date + 2.days, stored_at: Time.current },
      { from: "GBP", to: "USD", date: @date, stored_at: Time.current }
    ])

    assert_equal [ @date ], @account.syncs.pluck(:window_start_date)
  end

  # A security priced in another currency is converted into the account's
  # when its holdings are built, at 1:1 when there is no rate, and the holding
  # is stored in the account's currency -- so it is found by its price.
  test "an account holding a security priced in the changed currency is synced" do
    security = Security.create!(ticker: "EURX#{SecureRandom.hex(3)}", name: "EUR fund")
    Security::Price.create!(security: security, date: @date, price: 100, currency: "EUR")
    @account.holdings.create!(security: security, date: @date, qty: 1, price: 100, amount: 100, currency: "USD")
    ExchangeRate.create!(from_currency: "EUR", to_currency: "USD", date: @date, rate: 1.1)

    ExchangeRate::BalanceRefresh.schedule([ { from: "EUR", to: "USD", date: @date, stored_at: Time.current } ])

    assert_equal [ @date ], @account.syncs.pluck(:window_start_date)
  end

  # A running sync cannot widen its window, so it is asked for a full resync
  # when it finishes rather than having the request dropped.
  test "an account already syncing is resynced in full after it finishes" do
    eur_deposit(account: @account, date: @date, amount: 100)
    ExchangeRate.create!(from_currency: "EUR", to_currency: "USD", date: @date, rate: 1.1)
    running = @account.syncs.create!(status: "syncing")
    Account.any_instance.expects(:sync_later).never

    assert_no_difference "Sync.count" do
      ExchangeRate::BalanceRefresh.schedule([ { from: "EUR", to: "USD", date: @date, stored_at: Time.current } ])
    end
    assert running.reload.full_resync_requested
  end

  # What the balance never converted cannot be what is wrong with it: an
  # entry scheduled after today, or an account on its way out.
  # Read, then locked: a sync that finished in between already read its flag,
  # so the account is synced afresh instead of flagging a finished sync.
  test "a sync that stopped syncing before it was flagged leaves the account synced afresh" do
    eur_deposit(account: @account, date: @date, amount: 100)
    ExchangeRate.create!(from_currency: "EUR", to_currency: "USD", date: @date, rate: 1.1)
    running = @account.syncs.create!(status: "syncing")
    Sync.any_instance.stubs(:syncing?).returns(false)
    Account.any_instance.expects(:sync_later).with(window_start_date: @date).once

    ExchangeRate::BalanceRefresh.schedule([ { from: "EUR", to: "USD", date: @date, stored_at: Time.current } ])

    assert_not running.reload.full_resync_requested
  end

  test "scheduled entries and accounts pending deletion are left alone" do
    today = Date.current
    eur_deposit(account: @account, date: today + 2.days, amount: 100)
    leaving = usd_account
    eur_deposit(account: leaving, date: today, amount: 100)
    leaving.update_columns(status: "pending_deletion")
    ExchangeRate.create!(from_currency: "EUR", to_currency: "USD", date: today, rate: 1.1)

    assert_no_difference "Sync.count" do
      ExchangeRate::BalanceRefresh.schedule([ { from: "EUR", to: "USD", date: today, stored_at: Time.current } ])
    end
  end

  test "the job refreshes the rates it is given" do
    eur_deposit(account: @account, date: @date, amount: 100)
    ExchangeRate.create!(from_currency: "EUR", to_currency: "USD", date: @date, rate: 1.1)

    ExchangeRateBalanceRefreshJob.perform_now([ { from: "EUR", to: "USD", date: @date, stored_at: Time.current } ])

    assert_equal [ @date ], @account.syncs.pluck(:window_start_date)
  end

  test "no changed rates schedule nothing" do
    eur_deposit(account: @account, date: @date, amount: 100)

    assert_no_difference "Sync.count" do
      ExchangeRate::BalanceRefresh.schedule([])
    end
  end

  private
    def usd_account
      @family.accounts.create!(name: "USD #{SecureRandom.hex(3)}", balance: 0, currency: "USD", accountable: Depository.new)
    end

    def eur_deposit(account:, date:, amount:)
      account.entries.create!(name: "EUR deposit", date: date, amount: -amount, currency: "EUR", entryable: Transaction.new)
    end

    def closing_balance(account)
      account.balances.where(currency: account.currency).order(date: :desc).pick(:end_balance) || 0
    end
end
