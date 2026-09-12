require "test_helper"

# End-to-end acceptance scenarios for the "mid-day provider reading frozen as a waypoint" bug.
#
# Each scenario drives one real provider cycle through `PlaidAccount::Processor#process` with
# only the transaction sub-processor replaced by a stand-in, so the processor - not the test -
# decides whether the balance reading is taken before or after the batch is imported. Every
# assertion is on what the user can observe afterwards: materialized Balance rows and the
# valuation entries rendered in the account's activity list. Nothing here asserts on
# Valuation#kind or on how many `current_anchor` rows exist.
class AnchorBehaviorScenariosTest < ActiveSupport::TestCase
  # Provider readings are taken mid-day (the default auto-sync cron runs at 02:22), which is
  # the whole reason a reading is not a valid end-of-day balance for its own date.
  SYNC_TIME_OF_DAY = "02:22"

  setup do
    @day_one = Date.current
    @plaid_account = plaid_accounts(:one)

    # accounts(:connected) is the depository linked to plaid_accounts(:one); asserted rather
    # than assumed, since every balance below is derived from the ledger this test builds.
    assert_equal 0, accounts(:connected).entries.count
  end

  # A. The reported bug. Freezing day one's MID-DAY reading (1000) as an end-of-day waypoint
  # pins day one's close at 1000 instead of its true 600 and inflates every earlier day by the
  # 400 that posted after the reading was taken. Asserted immediately after the day-two sync
  # AND again after a quiet day-three sync, so neither a lagging fix nor one that corrupts
  # history when it finally settles the reading can pass.
  test "a mid-day reading is not frozen as that day's closing balance" do
    account = seed_opening_balance(1000)

    # Day one, 02:22: provider reports 1000. Nothing has posted yet.
    provider_sync!(@plaid_account, on: day(1), reading: 1000)

    # Day two, 02:22: the 400 that posted after yesterday's reading arrives in this batch,
    # dated to day one (normal for overnight PSD2 / Enable Banking batches), and the
    # provider now reports 600.
    provider_sync!(
      @plaid_account,
      on: day(2),
      reading: 600,
      imports: [ { date: day(1), amount: 400, name: "Card payment" } ]
    )

    materialize!(account)

    day_one_row = balance_row(account, day(1))
    assert_equal 600, day_one_row.balance,
      "day one's CLOSING balance must be its true close (600), not the mid-day reading (1000)"
    assert_equal 1000, day_one_row.start_cash_balance,
      "day one opened at 1000 and closed at 600 after the 400 posted"

    assert_equal 1000, balance_on(account, day(0)),
      "the day before the reading must not be inflated by the 400 that posted after it"
    assert_not_equal 1400, balance_on(account, day(0))
    assert_equal 1000, balance_on(account, day(-2))

    # Day three: an ordinary sync with nothing new. A design that defers settling the day-one
    # reading settles it here; history must be unchanged.
    provider_sync!(@plaid_account, on: day(3), reading: 600)

    materialize!(account)

    assert_equal 600, balance_on(account, day(1))
    assert_equal 1000, balance_on(account, day(0))
    assert_equal 1000, balance_on(account, day(-2))
    assert_equal 600, balance_on(account, day(3)), "today's balance is still the provider's"
  end

  # B. The waypoint that must survive (no regression of #1492 / #1484). The reading moves
  # 1000 -> 2000 with no transaction to explain it (missing / truncated history). Without a
  # provider-confirmed ground truth somewhere in the chain, the reverse walk silently reads
  # 2000 all the way back. Deliberately does not assert WHERE that ground truth is recorded.
  test "history stays grounded at the provider's reading when the ledger cannot explain a move" do
    account = seed_opening_balance(1000)

    provider_sync!(@plaid_account, on: day(1), reading: 1000)

    # No batch: the transaction that moved the account never reaches us.
    provider_sync!(@plaid_account, on: day(2), reading: 2000)
    provider_sync!(@plaid_account, on: day(3), reading: 2000)

    materialize!(account)

    assert_equal 2000, balance_on(account, day(3)), "today is still the provider's reading"

    assert_equal 1000, balance_on(account, day(0)),
      "the unexplained +1000 must not propagate to days before the reading that proves it"
    assert_not_equal 2000, balance_on(account, day(0))
    assert_equal 1000, balance_on(account, day(-2)),
      "drift must stay bounded all the way back to the opening balance"
  end

  # C. User-visible clutter at steady state. AccountsController#show renders every valuation
  # row on a linked account as a line item (no filter on entryable_type or Valuation#kind), so
  # six days of fully explained syncs must leave at most the one live reading behind - not a
  # daily "Manual balance update", and not a leftover unsettled reading.
  test "ordinary syncs whose ledger explains every move leave no valuation clutter behind" do
    account = nil

    # Each day's 100 posts after that day's 02:22 reading, so it arrives dated to the
    # previous day in the next day's batch - and the reading always trails by exactly it.
    (1..6).each do |n|
      account = provider_sync!(
        @plaid_account,
        on: day(n),
        reading: 1000 - (100 * (n - 1)),
        imports: n == 1 ? [] : [ { date: day(n - 1), amount: 100, name: "Day #{n - 1} spend" } ]
      )
    end

    materialize!(account)

    # Guard rail: the count assertion below must not be satisfiable by throwing history away.
    assert_equal 500, balance_on(account, day(6))
    assert_equal 900, balance_on(account, day(1))

    visible = user_visible_valuation_entries(account)

    assert_operator visible.count, :<=, 1,
      "after six explained syncs the user should see at most the live reading, " \
      "not a daily balance-update entry and not a leftover unsettled reading " \
      "(saw: #{visible.map { |e| [ e.date.to_s, e.name, e.amount.to_i ] }.inspect})"
  end

  # D. Liability sign math across a multi-day gap. On a credit card a positive entry amount
  # INCREASES the balance; getting that backwards turns an explained move into an unexplained
  # one and strands a waypoint at the wrong value. Also checks that gap length is not assumed
  # to be one day.
  test "a liability reading survives a multi-day gap with the right sign math" do
    card_plaid_account = create_credit_card_plaid_account

    account = provider_sync!(card_plaid_account, on: day(1), reading: 500)
    assert_equal "liability", account.classification

    seed_opening_balance(500, account: account)

    # Three days later: the backlog arrives, including the purchase that posted after day
    # one's reading. 500 + 30 + 20 - 100 = 450.
    account = provider_sync!(
      card_plaid_account,
      on: day(4),
      reading: 450,
      imports: [
        { date: day(1), amount: 30, name: "Purchase" },
        { date: day(2), amount: 20, name: "Purchase" },
        { date: day(3), amount: -100, name: "Payment" }
      ]
    )

    materialize!(account)

    assert_equal 530, balance_on(account, day(1)),
      "day one closed at 530: the reading was taken before the 30 purchase posted"
    assert_equal 550, balance_on(account, day(2))
    assert_equal 450, balance_on(account, day(3))
    assert_equal 450, balance_on(account, day(4))
    assert_equal 500, balance_on(account, day(0)),
      "days before the gap must not shift because of the backlog"

    # Settle-later designs get their chance; history must survive it unchanged.
    account = provider_sync!(card_plaid_account, on: day(5), reading: 450)
    materialize!(account)

    assert_equal 530, balance_on(account, day(1))
    assert_equal 500, balance_on(account, day(0))
    assert_equal 450, balance_on(account, day(5))
  end

  # E. Repeat syncs on the same day (many providers sync several times a day) must neither
  # accumulate valuation rows nor turn a superseded intra-day reading into an end-of-day
  # waypoint, which would pin day one at 1000 rather than its true 900.
  test "repeat syncs on the same day neither accumulate rows nor freeze intra-day readings" do
    provider_sync!(@plaid_account, on: day(1), reading: 1000)

    account = provider_sync!(
      @plaid_account,
      on: day(2),
      reading: 900,
      imports: [ { date: day(1), amount: 100, name: "Yesterday's spend" } ]
    )

    rows_after_first_cycle = user_visible_valuation_entries(account).count

    # Two more cycles the same day, one of them carrying a fresh batch.
    provider_sync!(
      @plaid_account,
      on: day(2),
      reading: 880,
      imports: [ { date: day(2), amount: 20, name: "Today's spend" } ]
    )
    account = provider_sync!(@plaid_account, on: day(2), reading: 880)

    assert_operator user_visible_valuation_entries(account).count, :<=, rows_after_first_cycle,
      "extra sync cycles on the same day must not add valuation rows the user can see"

    valuation_dates = user_visible_valuation_entries(account).map(&:date)
    assert_equal valuation_dates.uniq.size, valuation_dates.size,
      "the same date must never end up with more than one valuation row"

    materialize!(account)

    assert_equal 880, balance_on(account, day(2))
    assert_equal 900, balance_on(account, day(1)),
      "day one closed at 900; no intra-day reading may override that"
  end

  # F. A reading already carried forward onto a date contains the flows dated on that date.
  # Re-counting them decides an explained move is unexplained, freezes day two's 14:00 reading
  # (500) as that day's close, and inflates every earlier day by the 50 that posted after it.
  # True day-two close = 1000 - 400 - 100 - 50 = 450, exactly what the provider reports on
  # day three, so nothing here is ambiguous.
  test "a reading carried forward is not re-settled against flows it already contains" do
    account = seed_opening_balance(1000)

    provider_sync!(@plaid_account, on: day(1), reading: 1000)

    # Day two, 02:22: yesterday's 400 arrives; 1000 -> 600 is fully explained.
    provider_sync!(
      @plaid_account,
      on: day(2),
      reading: 600,
      imports: [ { date: day(1), amount: 400, name: "Day 1 spend" } ]
    )

    # Day two, second cycle: 100 posts today and the reading follows it down.
    provider_sync!(
      @plaid_account,
      on: day(2),
      reading: 500,
      imports: [ { date: day(2), amount: 100, name: "Day 2 spend (early)" } ]
    )

    # Day three: the 50 that posted after day two's last reading arrives, dated to day two.
    account = provider_sync!(
      @plaid_account,
      on: day(3),
      reading: 450,
      imports: [ { date: day(2), amount: 50, name: "Day 2 spend (late)" } ]
    )

    materialize!(account)

    assert_equal 450, balance_on(account, day(2)),
      "day two closed at 450; the 500 reading was taken before the last 50 posted"
    assert_equal 600, balance_on(account, day(1))
    assert_equal 1000, balance_on(account, day(0)),
      "days before the reading must not be inflated by what posted after it"
    assert_equal 450, balance_on(account, day(3))

    # Excludes only the opening balance this test seeded itself, so the count is about
    # rows the syncs produced - and stays kind-agnostic, like the rest of this file.
    visible = user_visible_valuation_entries(account).reject { |e| e.date == day(-4) }
    assert_operator visible.count, :<=, 1,
      "every move here is explained by the ledger, so no waypoint is warranted " \
      "(saw: #{visible.map { |e| [ e.date.to_s, e.name, e.amount.to_i ] }.inspect})"
  end

  private
    # day(1) is "day one" in the scenarios above; day(0) is the day before it.
    def day(offset)
      @day_one + (offset - 1).days
    end

    def sync_clock(date)
      Time.zone.parse("#{date} #{SYNC_TIME_OF_DAY}")
    end

    # Always hand back a freshly loaded Account: Account::Anchorable memoizes its
    # CurrentBalanceManager, which memoizes its anchor lookup.
    def account_for(plaid_account)
      Account.find(PlaidAccount.find(plaid_account.id).current_account.id)
    end

    # One full provider cycle, driven through the real processor. Returns a fresh Account.
    def provider_sync!(plaid_account, on:, reading:, imports: [])
      travel_to sync_clock(on) do
        PlaidAccount.find(plaid_account.id).update!(
          current_balance: reading,
          available_balance: reading
        )

        imported = []
        stub_provider_subprocessors(plaid_account, imports, imported)

        PlaidAccount::Processor.new(PlaidAccount.find(plaid_account.id)).process

        # PlaidAccount::Processor#process_transactions swallows exceptions, so prove the
        # batch actually landed instead of vanishing into a rescue.
        assert_equal imports.size, imported.size,
          "the provider's transaction batch did not import on #{on}"
      end

      account_for(plaid_account)
    end

    # Replaces only the transaction importer with a stand-in that creates this cycle's entries
    # at exactly the point where the real import happens; the other sub-processors are no-ops.
    def stub_provider_subprocessors(plaid_account, imports, imported)
      importer = Object.new
      importer.define_singleton_method(:process) do
        imports.each do |txn|
          account = Account.find(PlaidAccount.find(plaid_account.id).current_account.id)

          entry = account.entries.create!(
            date: txn[:date],
            name: txn[:name] || "Imported transaction",
            amount: txn[:amount],
            currency: txn[:currency] || account.currency,
            entryable: Transaction.new
          )

          imported << entry.id
        end
      end

      PlaidAccount::Transactions::Processor.stubs(:new).returns(importer)
      PlaidAccount::Investments::TransactionsProcessor.any_instance.stubs(:process)
      PlaidAccount::Investments::HoldingsProcessor.any_instance.stubs(:process)
      PlaidAccount::Liabilities::CreditProcessor.any_instance.stubs(:process)
      PlaidAccount::Liabilities::MortgageProcessor.any_instance.stubs(:process)
      PlaidAccount::Liabilities::StudentLoanProcessor.any_instance.stubs(:process)
    end

    # Gives the account a history to be wrong about: without an opening anchor the reverse
    # walk stops at the oldest entry and there are no "earlier days" to inflate.
    def seed_opening_balance(amount, account: nil)
      account ||= accounts(:connected)

      account.entries.create!(
        date: day(-4),
        name: "Opening balance",
        amount: amount,
        currency: account.currency,
        entryable: Valuation.new(kind: "opening_anchor")
      )

      Account.find(account.id)
    end

    def create_credit_card_plaid_account
      PlaidAccount.create!(
        plaid_item: plaid_items(:one),
        plaid_id: "acc_mock_credit_card",
        name: "Test Credit Card",
        plaid_type: "credit",
        plaid_subtype: "credit card",
        currency: "USD",
        current_balance: 500,
        available_balance: 500
      )
    end

    def materialize!(account)
      Balance::Materializer.new(Account.find(account.id), strategy: :reverse).materialize_balances
    end

    def balance_row(account, date)
      row = Account.find(account.id).balances.find_by(date: date, currency: account.currency)
      assert_not_nil row, "expected a materialized balance for #{date}"
      row
    end

    def balance_on(account, date)
      balance_row(account, date).balance
    end

    # What the user actually sees: AccountsController#show builds the activity list from
    # `account.entries.excluding_split_parents.search(@q)`, and entries/_entry.html.erb renders
    # a valuation through the same row template as a transaction.
    def user_visible_valuation_entries(account)
      Account.find(account.id)
        .entries
        .excluding_split_parents
        .where(entryable_type: "Valuation")
        .order(:date)
    end
end
