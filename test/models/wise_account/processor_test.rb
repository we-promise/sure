require "test_helper"

class WiseAccount::ProcessorTest < ActiveSupport::TestCase
  setup do
    @family = families(:empty)
    @wise_item = WiseItem.create!(family: @family, name: "Test Wise", token: "test_token", profile_id: "123", profile_type: :business)
    @wise_account = @wise_item.wise_accounts.create!(balance_id: "10000001", name: "Wise EUR", currency: "EUR", current_balance: 0,
                                                     raw_payload: { "type" => "STANDARD", "recipient_id" => 99999001 })
  end

  # Current balance: an anchor left by another provider follows the Wise
  # balance in place, so a card payment Wise completes after a sync, dated on
  # that day, does not shift the days before it.
  test "keeps another provider's current anchor on the live balance without reconciliations" do
    @family.update!(timezone: "Europe/Dublin")
    account = link(@wise_account)
    account.entries.create!(date: Date.new(2025, 7, 21), name: "Current balance", amount: 40, currency: "EUR",
                            entryable: Valuation.new(kind: "current_anchor"))
    top_up = { "id" => 1, "targetAccount" => 99999001, "sourceCurrency" => "EUR", "targetCurrency" => "EUR",
               "sourceValue" => 100.0, "targetValue" => 100.0, "status" => "outgoing_payment_sent", "created" => "2025-08-08 09:00:00" }
    card = { "id" => "card_1", "type" => "CARD_PAYMENT", "resource" => { "type" => "CARD_TRANSACTION", "id" => "1" },
             "title" => "<strong>Bakery</strong>", "primaryAmount" => "30 EUR", "secondaryAmount" => "",
             "status" => "IN_PROGRESS", "createdOn" => "2025-08-13T19:00:00.000Z" }

    # The hold is counted back in while the payment is pending.
    before = travel_to(Time.utc(2025, 8, 13, 20)) do
      sync(account, current_balance: 100, rows: [ top_up, card ])
    end
    assert_equal [ Date.new(2025, 8, 13), BigDecimal("100") ], current_anchor(account)

    # A day later (23:30 UTC is already 15 August in Dublin) the payment
    # completed, dated the 13th: yesterday's anchor is moved, not kept as a
    # reconciliation that would put the payment back onto every earlier day.
    after = travel_to(Time.utc(2025, 8, 14, 23, 30)) do
      sync(account, current_balance: 70, rows: [ top_up, card.merge("status" => "COMPLETED") ])
    end

    assert_equal [ Date.new(2025, 8, 15), BigDecimal("70") ], current_anchor(account)
    assert_empty account.valuations.reconciliation
    assert_equal before.select { |date, _| date < Date.new(2025, 8, 13) }, after.select { |date, _| date < Date.new(2025, 8, 13) }
    assert_equal BigDecimal("100"), after[Date.new(2025, 8, 10)]
    assert_equal BigDecimal("70"), after[Date.new(2025, 8, 13)]
  end

  # The history used to stop at the stale anchor (1 September, 500) although
  # Wise reported 800.
  test "an account linked from another provider follows the Wise balance" do
    travel_to Time.utc(2026, 10, 17, 12) do
      account = @family.accounts.create!(name: "Wise (EUR)", balance: 500, cash_balance: 500, currency: "EUR", accountable: Depository.new)
      account.entries.create!(date: Date.new(2025, 11, 26), name: "Opening balance", amount: 0, currency: "EUR",
                              entryable: Valuation.new(kind: "opening_anchor"))
      account.entries.create!(date: Date.new(2026, 9, 1), name: "Current balance", amount: 500, currency: "EUR",
                              entryable: Valuation.new(kind: "current_anchor"))
      AccountProvider.create!(account: account, provider: @wise_account)
      top_up = { "id" => 554, "targetAccount" => 99999001, "sourceCurrency" => "EUR", "targetCurrency" => "EUR",
                 "sourceValue" => 600.0, "targetValue" => 600.0, "status" => "outgoing_payment_sent", "created" => "2026-09-15 10:00:00" }
      sent = payout(555, created: "2026-10-10 10:00:00").merge("sourceValue" => 300.0, "targetValue" => 300.0)
      @wise_account.update!(current_balance: 800, raw_transactions_payload: [ top_up, sent ])

      WiseAccount::Processor.new(@wise_account).process
      Balance::Materializer.new(Account.find(account.id), strategy: :reverse).materialize_balances

      latest = account.balances.order(:date).last
      assert_equal [ Date.current, BigDecimal("800") ], [ latest.date, latest.balance ]
      assert_equal BigDecimal("1100"), account.balances.find_by!(date: Date.new(2026, 10, 9)).balance
    end
  end

  test "sets the account balance without an anchor of its own" do
    account = link(@wise_account)
    @wise_account.update!(current_balance: 25.5)

    WiseAccount::Processor.new(@wise_account).process

    assert_equal BigDecimal("25.5"), account.reload.balance
    assert_empty account.valuations.current_anchor
  end

  # Processing and the clean-up run under the balance's lock, on the payload
  # as it stands once the lock is held.
  test "processes under the balance's lock the payload a sync stored meanwhile" do
    account = link(@wise_account)
    waiting = WiseAccount.find(@wise_account.id)
    WiseAccount.find(@wise_account.id).update!(raw_transactions_payload: [ payout(4711) ])

    WiseAccount::Processor.new(waiting).process

    assert_equal [ "wise_transfer_4711" ], account.entries.pluck(:external_id)
  end

  test "books nothing unless it holds the balance's lock" do
    account = link(@wise_account)
    @wise_account.update!(current_balance: 25.5, raw_transactions_payload: [ payout(4711) ])
    @wise_account.expects(:with_processing_lock).returns(nil)

    WiseAccount::Processor.new(@wise_account).process

    assert_empty account.entries
    assert_equal 0, account.reload.balance
  end

  # The opening balance repair.
  test "moves an opening balance made at the live balance to 0 the day before Wise opened the balance, once" do
    @family.update!(timezone: "Europe/Dublin")
    account = full_history_account(creation_time: "2025-03-26T08:00:00Z")
    assert_equal [ 2.years.ago.to_date, BigDecimal("80") ], opening_anchor(account)

    assert_difference -> { anchor_notes.where(level: "info").count }, 1 do
      WiseAccount::Processor.new(@wise_account, import_complete: true).process
    end
    assert_equal [ Date.new(2025, 3, 25), BigDecimal("0") ], opening_anchor(account)

    assert_no_difference -> { anchor_notes.count } do
      WiseAccount::Processor.new(@wise_account, import_complete: true).process
    end
    assert_equal [ Date.new(2025, 3, 25), BigDecimal("0") ], opening_anchor(account)
  end

  # A pay-in that makes Wise open the balance can be created before it, and
  # may only be listed after the opening balance was moved.
  test "opens the balance before a row booked earlier than the day before Wise opened it" do
    account = full_history_account(creation_time: "2025-10-29T00:10:00Z")
    WiseAccount::Processor.new(@wise_account, import_complete: true).process
    assert_equal [ Date.new(2025, 10, 28), BigDecimal("0") ], opening_anchor(account)

    @wise_account.update!(raw_transactions_payload: [ payout(4711, created: "2025-10-24 20:00:00") ])
    WiseAccount::Processor.new(@wise_account, import_complete: true).process

    assert_equal [ Date.new(2025, 10, 23), BigDecimal("0") ], opening_anchor(account)
  end

  test "creates the opening balance at 0 the day before Wise opened a full-history balance" do
    @family.update!(timezone: "Europe/Dublin")
    @wise_item.update!(import_all_history: true)
    @wise_account.update!(current_balance: 80, raw_payload: @wise_account.raw_payload.merge("creationTime" => "2025-04-16T10:00:00Z"))

    account = Account.create_from_wise_account(@wise_account)

    assert_equal [ Date.new(2025, 4, 15), BigDecimal("0") ], opening_anchor(account)
    assert_equal BigDecimal("80"), account.balance
  end

  test "creates the opening balance as before without the full history" do
    @wise_account.update!(current_balance: 80, raw_payload: @wise_account.raw_payload.merge("creationTime" => "2025-11-12T10:00:00Z"))

    account = Account.create_from_wise_account(@wise_account)

    assert_equal [ 2.years.ago.to_date, BigDecimal("80") ], opening_anchor(account)
  end

  test "leaves the opening balance alone unless every condition for moving it holds" do
    {
      "after an incomplete import" => [ {}, { import_complete: false } ],
      "without the full history" => [ { full_history: false }, {} ],
      "with coverage starting after the balance opened" => [ { covered_from: "2025-12-09T00:00:00Z" }, {} ],
      "on an account with a transaction of its own" => [ { manual_entry: true }, {} ]
    }.each do |label, (setup, options)|
      @wise_account.account_provider&.destroy!
      account = full_history_account(creation_time: "2025-12-03T08:00:00Z", **setup)

      WiseAccount::Processor.new(@wise_account.reload, import_complete: options.fetch(:import_complete, true)).process

      assert_equal [ 2.years.ago.to_date, BigDecimal("80") ], opening_anchor(account), label
    end
    assert_empty anchor_notes
  end

  # The valuation drawer saves a person's edit through
  # Account#update_reconciliation, which does not mark the entry
  # user_modified, so the repair replaced the opening balance they entered. It
  # now moves only an anchor Sure set: the default made with the account,
  # never changed since, or the one it wrote last.
  test "keeps an opening balance a person changed, and says so" do
    {
      "edited in the valuation drawer" => ->(account, anchor) {
        assert account.update_reconciliation(anchor, balance: 120, date: Date.new(2026, 3, 1)).success?
      },
      "marked as edited" => ->(_account, anchor) { anchor.update!(user_modified: true) },
      "edited after Sure had moved it" => ->(account, anchor) {
        WiseAccount::Processor.new(@wise_account.reload, import_complete: true).process
        @wise_account.update!(raw_transactions_payload: [ payout(4711, created: "2026-03-20 12:00:00") ])
        assert account.update_reconciliation(anchor.reload, balance: 0, date: Date.new(2026, 3, 26)).success?
      }
    }.each do |label, change|
      @wise_account.account_provider&.destroy!
      account = full_history_account(creation_time: "2026-04-02T08:00:00Z")
      anchor = account.valuations.opening_anchor.sole.entry
      change.call(account, anchor)
      kept = opening_anchor(account)

      assert_difference -> { anchor_notes.where(level: "info").count }, 1, label do
        WiseAccount::Processor.new(@wise_account.reload, import_complete: true).process
      end

      assert_equal kept, opening_anchor(account), label
      assert_equal kept.first.iso8601, anchor_notes.order(:created_at).last.metadata["kept_opening_date"], label
    end
  end

  # An anchor Sure set (here when it created the account) stays Sure's to
  # move, e.g. for a pay-in listed later that Wise created before it opened
  # the balance.
  test "moves again the opening balance it set when it created the account" do
    @wise_item.update!(import_all_history: true)
    @wise_item.merge_sync_metadata!("coverage" => %w[transfers activities].index_with {
      { "from" => "2025-06-24T07:59:00Z", "through" => "2026-10-17T12:00:00Z", "version" => WiseItem::COVERAGE_VERSION }
    })
    @wise_account.update!(raw_payload: @wise_account.raw_payload.merge("creationTime" => "2025-06-25T08:00:00Z"))
    account = Account.create_from_wise_account(@wise_account)
    AccountProvider.create!(account: account, provider: @wise_account)
    assert_equal [ Date.new(2025, 6, 24), BigDecimal("0") ], opening_anchor(account)

    @wise_account.update!(raw_transactions_payload: [ payout(4711, created: "2025-06-11 12:00:00") ])
    WiseAccount::Processor.new(@wise_account.reload, import_complete: true).process

    assert_equal [ Date.new(2025, 6, 10), BigDecimal("0") ], opening_anchor(account)
  end

  # The default opening balance was dated two years back in the zone of the
  # request that created the account (the family's zone then), and a sync runs
  # in the zone of the request that started it, or in UTC when scheduled. An
  # account created at 22:15 UTC from a request in Honolulu (UTC-10) has its
  # anchor dated 9 Jul 2024; a sync running in Tokyo, where that instant is
  # 10 Jul, took it for an anchor a person set and never moved it.
  test "moves a default opening balance dated in another time zone than the sync runs in" do
    @family.update!(timezone: "Europe/Dublin")
    {
      "made at 22:15 UTC in Honolulu, synced in Tokyo" => [ Time.utc(2026, 7, 9, 22, 15, 15), "Pacific/Honolulu", "Asia/Tokyo" ],
      "made at 00:30 in Dublin, synced in UTC" => [ Time.utc(2026, 6, 18, 23, 30), "Europe/Dublin", "UTC" ],
      "made at 20:30 in New York, synced in UTC" => [ Time.utc(2026, 6, 10, 0, 30), "America/New_York", "UTC" ]
    }.each do |label, (made_at, made_in, synced_in)|
      @wise_account.account_provider&.destroy!
      account = travel_to(made_at) { Time.use_zone(made_in) { full_history_account(creation_time: "2026-03-12T08:00:00Z") } }
      assert_equal made_at.in_time_zone(made_in).to_date - 2.years, opening_anchor(account).first, label

      travel_to(Time.utc(2026, 10, 18, 12)) do
        Time.use_zone(synced_in) { WiseAccount::Processor.new(@wise_account.reload, import_complete: true).process }
      end

      assert_equal [ Date.new(2026, 3, 11), BigDecimal("0") ], opening_anchor(account), label
    end
    assert_empty anchor_notes.select { |note| note.metadata.key?("kept_opening_date") }
  end

  test "reports an opening balance it cannot move and processes the account anyway" do
    account = full_history_account(creation_time: "2024-11-20T08:00:00Z", rows: [ payout(4711) ])
    Account::OpeningBalanceManager.any_instance.stubs(:set_opening_balance)
                                  .returns(Account::OpeningBalanceManager::Result.new(success?: false, changes_made?: false,
                                                                                      error: "Opening balance date must be before the oldest entry date"))

    result = WiseAccount::Processor.new(@wise_account, import_complete: true).process

    assert_equal 1, result[:imported]
    assert_equal [ "wise_transfer_4711" ], account.entries.where(source: "wise").pluck(:external_id)
    assert_equal "warn", anchor_notes.sole.level
  end

  private

    def link(wise_account, balance: 0)
      account = Account.create!(family: @family, name: wise_account.name, balance: balance, currency: wise_account.currency,
                                accountable: Depository.new(subtype: "checking"))
      AccountProvider.create!(account: account, provider: wise_account)
      account
    end

    # An account set up by an older build: its opening anchor is today's
    # balance two years back. The item imports the full history and covered
    # the balance back to `covered_from`.
    def full_history_account(creation_time:, rows: [], full_history: true, covered_from: "2024-11-06T05:13:00Z",
                             manual_entry: false)
      @wise_item.update!(import_all_history: full_history, raw_payload: nil)
      @wise_item.merge_sync_metadata!("coverage" => %w[transfers activities].index_with {
        { "from" => covered_from, "through" => "2026-10-17T12:00:00Z", "version" => WiseItem::COVERAGE_VERSION }
      })
      @wise_account.update!(current_balance: 80, raw_transactions_payload: rows,
                            raw_payload: @wise_account.raw_payload.merge("creationTime" => creation_time))
      account = Account.create_and_sync({ family: @family, name: "Wise EUR", balance: 80, currency: "EUR",
                                          accountable_type: "Depository", accountable_attributes: { subtype: "checking" } },
                                        skip_initial_sync: true)
      AccountProvider.create!(account: account, provider: @wise_account)
      account.entries.create!(date: Date.new(2026, 6, 1), name: "Cash", amount: 5, currency: "EUR", entryable: Transaction.new) if manual_entry
      account
    end

    def payout(id, created: "2026-10-10 12:00:00")
      { "id" => id, "targetAccount" => 4242, "sourceCurrency" => "EUR", "targetCurrency" => "EUR",
        "sourceValue" => 25.0, "targetValue" => 25.0, "status" => "outgoing_payment_sent", "created" => created }
    end

    # Processes the balance as a sync's processing would, then the balance
    # history as the account sync after it does, on a freshly loaded account
    # (it memoizes its anchors): { date => end balance }.
    def sync(account, current_balance:, rows:)
      @wise_account.update!(current_balance: current_balance, raw_transactions_payload: rows)
      WiseAccount::Processor.new(@wise_account, import_complete: true).process
      Balance::Materializer.new(Account.find(account.id), strategy: :reverse).materialize_balances
      account.balances.order(:date).to_h { |balance| [ balance.date, balance.balance ] }
    end

    def current_anchor(account)
      account.valuations.current_anchor.sole.entry.then { |entry| [ entry.date, entry.amount ] }
    end

    def opening_anchor(account)
      account.valuations.opening_anchor.sole.entry.reload.then { |entry| [ entry.date, entry.amount ] }
    end

    def anchor_notes
      DebugLogEntry.where(provider_key: "wise").where("metadata ->> 'operation' = ?", "opening_anchor")
    end
end
