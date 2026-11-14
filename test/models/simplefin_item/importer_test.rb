require "test_helper"

class SimplefinItem::ImporterTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @family = families(:dylan_family)
    @item = SimplefinItem.create!(
      family: @family,
      name: "SimpleFIN Importer Test",
      access_url: "https://example.com/access"
    )
    @importer = SimplefinItem::Importer.new(@item, simplefin_provider: nil)
  end

  test "normalizes numeric-string epoch balance-date for importer upserts" do
    epoch_string = Time.utc(2026, 6, 17, 12, 34, 56).to_i.to_s

    parsed = @importer.send(:normalize_balance_date, epoch_string)

    assert_equal Time.at(epoch_string.to_i).utc, parsed
  end

  test "changed holdings preserve the latest account snapshot" do
    source = create_simplefin_account("sf_snapshot", "Brokerage", "investment", 100)
    source.update!(raw_payload: { balance: "100", extra: { revision: "old" } },
      raw_holdings_payload: [ { "id" => "position", "shares" => "1" } ])
    payload = {
      id: source.account_id, name: "Renamed brokerage", currency: "USD", balance: "200",
      "balance-date": Time.current.to_i, extra: { revision: "new" },
      holdings: [ { "id" => "position", "shares" => "2" } ]
    }

    @importer.send(:import_account, payload)

    assert_equal payload.deep_stringify_keys, source.reload.raw_payload
    assert_equal payload[:holdings], source.raw_holdings_payload
  end

  test "an explicit empty holdings snapshot clears saved holdings and refreshes cash" do
    source = create_simplefin_account("sf_empty", "Brokerage", "investment", 100)
    holdings = [ { "id" => "position", "symbol" => "AAPL", "market_value" => "100" } ]
    source.update!(raw_payload: { holdings: holdings }, raw_holdings_payload: holdings)
    account = accounts(:investment)
    account.update!(simplefin_account_id: source.id, cash_balance: 0)
    SimplefinHoldingsApplyJob.expects(:perform_later).with(source.id).once

    @importer.send(:import_account, {
      id: source.account_id, name: "Brokerage", currency: "USD", balance: "100", holdings: []
    })

    assert_equal [], source.reload.raw_holdings_payload
    assert_equal [], source.raw_payload["holdings"]
    assert_equal 100, account.reload.cash_balance
  end

  test "omitted holdings preserve the saved holdings snapshot" do
    source = create_simplefin_account("sf_omitted", "Brokerage", "investment", 100)
    holdings = [ { "id" => "position", "shares" => "1" } ]
    source.update!(raw_holdings_payload: holdings)
    accounts(:investment).update!(simplefin_account_id: source.id)
    SimplefinHoldingsApplyJob.expects(:perform_later).never

    @importer.send(:import_account, {
      id: source.account_id, name: "Brokerage", currency: "USD", balance: "100"
    })

    assert_equal holdings, source.reload.raw_holdings_payload
  end

  test "unchanged symbol-keyed holdings do not enqueue another apply job" do
    source = create_simplefin_account("sf_unchanged", "Brokerage", "investment", 100)
    holdings = [ { id: "position", shares: "1" } ]
    source.update!(raw_holdings_payload: holdings)
    accounts(:investment).update!(simplefin_account_id: source.id)
    SimplefinHoldingsApplyJob.expects(:perform_later).never

    @importer.send(:import_account, {
      id: source.account_id, name: "Brokerage", currency: "USD", balance: "100", holdings: holdings
    })

    assert_equal holdings.as_json, source.reload.raw_holdings_payload
  end

  test "a later crypto snapshot is applied after an empty snapshot job already ran" do
    source = create_simplefin_account("sf_crypto", "Crypto", "investment", 100)
    account = accounts(:crypto)
    account.update!(simplefin_account_id: source.id)
    source.ensure_account_provider!
    holding = { "id" => "position", "symbol" => "CUSTOM:SNAPSHOT", "shares" => "2", "market_value" => "100", "currency" => "USD" }
    source.update!(raw_holdings_payload: [ holding ])
    payload = { id: source.account_id, name: "Crypto", currency: "USD", balance: "100" }

    perform_enqueued_jobs(only: SimplefinHoldingsApplyJob) do
      @importer.send(:import_account, payload.merge(holdings: []))
      @importer.send(:import_account, payload.merge(holdings: [ holding ]))
    end

    assert_equal [ 2.to_d ], account.current_holdings.pluck(:qty)
  end

  test "an older request preserves newer holdings and still imports transactions" do
    source = create_simplefin_account("sf_older", "Brokerage", "investment", 200)
    holding = { "id" => "position", "shares" => "2" }
    snapshot = { "balance" => "200", "holdings" => [ holding ] }
    source.update!(balance_date: Time.current, account_requested_at: Time.current, holdings_requested_at: Time.current, raw_payload: snapshot, raw_holdings_payload: [ holding ])

    @importer.send(:import_account, {
      id: source.account_id, name: "Old name", currency: "USD", balance: "0",
      "balance-date": 1.hour.ago.to_i, holdings: [],
      transactions: [ { "id" => "older-transaction", "posted" => 1.day.ago.to_i, "amount" => "-10" } ]
    }, requested_at: 1.minute.ago)

    assert_equal snapshot, source.reload.raw_payload
    assert_equal [ holding ], source.raw_holdings_payload
    assert_equal 200, source.current_balance
    assert_equal [ "older-transaction" ], source.raw_transactions_payload.pluck("id")
  end

  [ :import_account, :import_account_minimal_and_balance ].each do |newer_path|
    [ :import_account, :import_account_minimal_and_balance ].each do |older_path|
      [ nil, Time.utc(2026, 6, 17).to_i ].each do |balance_date|
        test "#{older_path} cannot overwrite newer #{newer_path} metadata with balance date #{balance_date.inspect}" do
          source = create_simplefin_account("sf_metadata", "Brokerage", "investment", 100)
          account = accounts(:investment)
          account.update!(simplefin_account_id: source.id)
          requested_at = Time.current.change(usec: 0)
          payload = { id: source.account_id, name: "New name", currency: "USD", balance: "200",
            "available-balance": "150", "balance-date": balance_date }
          @importer.send(newer_path, payload, requested_at: requested_at)
          account_values = account.reload.attributes.slice("balance", "cash_balance")

          @importer.send(older_path, payload.merge(name: "Old name", balance: "10", "available-balance": "5"),
            requested_at: requested_at - 1.minute)

          assert_equal "New name", source.reload.name
          assert_equal payload.deep_stringify_keys, source.raw_payload
          assert_equal 200, source.current_balance
          assert_equal 150, source.available_balance
          assert_equal requested_at, source.account_requested_at
          assert_equal account_values, account.reload.attributes.slice("balance", "cash_balance")
        end
      end
    end
  end

  test "a newer balances-only response does not suppress an older explicit holdings snapshot" do
    source = create_simplefin_account("sf_separate_ordering", "Brokerage", "investment", 100)
    requested_at = Time.current.change(usec: 0)
    payload = { id: source.account_id, name: "New name", currency: "USD", balance: "200" }
    holding = { "id" => "position", "shares" => "2" }
    source.update!(raw_holdings_payload: [], holdings_requested_at: requested_at - 2.minutes)
    @importer.send(:import_account_minimal_and_balance, payload.merge(holdings: []), requested_at: requested_at)

    @importer.send(:import_account, payload.merge(name: "Old name", balance: "100", holdings: [ holding ],
      transactions: [ { "id" => "historical", "posted" => 1.day.ago.to_i, "amount" => "-10" } ]),
      requested_at: requested_at - 1.minute)

    assert_equal "New name", source.reload.name
    assert_equal 200, source.current_balance
    assert_equal [ holding ], source.raw_holdings_payload
    assert_equal requested_at - 1.minute, source.holdings_requested_at
    assert_equal requested_at, source.account_requested_at
    assert_equal [ "historical" ], source.raw_transactions_payload.pluck("id")
  end

  test "balances-only imports retain a newer dated balance in both provider and linked account" do
    source = create_simplefin_account("sf_balance_date", "Checking", "depository", 200)
    account = accounts(:depository)
    account.update!(simplefin_account_id: source.id, balance: 200, cash_balance: 150)
    source.update!(balance_date: Time.current, available_balance: 150)

    @importer.send(:import_account_minimal_and_balance, {
      id: source.account_id, name: "Renamed checking", currency: "USD", balance: "10",
      "available-balance": "5", "balance-date": 1.hour.ago.to_i
    })

    assert_equal "Renamed checking", source.reload.name
    assert_equal 200, source.current_balance
    assert_equal 150, source.available_balance
    assert_equal 200, account.reload.balance
    assert_equal 150, account.cash_balance
  end

  [ :import_account, :import_account_minimal_and_balance ].each do |path|
    test "#{path} preserves accepted available credit when the balance date moves backwards" do
      source = create_simplefin_account("sf_credit_date", "Card", "credit", -100)
      account = accounts(:credit_card)
      account.update!(simplefin_account_id: source.id)
      account.accountable.update!(available_credit: 1000)
      source.update!(balance_date: Time.current, available_balance: 5000)

      @importer.send(path, { id: source.account_id, name: source.name, currency: "USD",
        balance: "-10", "available-balance": "5", "balance-date": 1.hour.ago.to_i })
      if path == :import_account_minimal_and_balance
        SimplefinAccount::Liabilities::CreditProcessor.new(source.reload).process
      end

      assert_equal(-100, source.current_balance)
      assert_equal 5000, source.available_balance
      assert_equal 5000, account.accountable.reload.available_credit
    end
  end

  test "an accepted empty holdings snapshot uses the full balance as cash after a newer balance-only response" do
    source = create_simplefin_account("sf_empty_cash", "Brokerage", "investment", 200)
    account = accounts(:investment)
    account.update!(simplefin_account_id: source.id, cash_balance: 100)
    provider = source.ensure_account_provider!
    account.holdings.delete_all
    account.holdings.create!(account_provider: provider, security: securities(:aapl), date: Date.yesterday,
      qty: 1, amount: 100, price: 100, currency: "USD")
    requested_at = Time.current.change(usec: 0)
    holding = { "id" => "position", "symbol" => "AAPL", "shares" => "1", "market_value" => "100" }
    source.update!(raw_holdings_payload: [ holding ], holdings_requested_at: requested_at - 2.minutes)
    payload = { id: source.account_id, name: source.name, currency: "USD", balance: "200" }
    @importer.send(:import_account_minimal_and_balance, payload.merge(holdings: [ holding ]), requested_at: requested_at)

    perform_enqueued_jobs(only: SimplefinHoldingsApplyJob) do
      @importer.send(:import_account, payload.merge(holdings: []), requested_at: requested_at - 1.minute)
    end

    assert_equal [], source.reload.raw_holdings_payload
    assert_empty account.current_holdings
    assert_equal 200, account.reload.cash_balance
  end

  test "new holdings with an older balance date apply without rolling back the balance" do
    source = create_simplefin_account("sf_fresh_holdings", "Crypto", "investment", 200)
    account = accounts(:crypto)
    account.update!(simplefin_account_id: source.id)
    source.ensure_account_provider!
    balance_date = Time.current.change(usec: 0)
    source.update!(balance_date: balance_date, raw_holdings_payload: [])
    holding = { "id" => "new-position", "symbol" => "CUSTOM:FRESH", "shares" => "2", "market_value" => "100", "currency" => "USD" }

    perform_enqueued_jobs(only: SimplefinHoldingsApplyJob) do
      @importer.send(:import_account, {
        id: source.account_id, name: source.name, currency: "USD", balance: "100",
        "balance-date": 1.hour.ago.to_i, holdings: [ holding ]
      })
    end

    assert_equal [ holding ], source.reload.raw_holdings_payload
    assert_equal 200, source.current_balance
    assert_equal balance_date, source.balance_date
    assert_equal [ 2.to_d ], account.current_holdings.pluck(:qty)
    assert_equal 100, account.reload.cash_balance
  end

  test "an empty snapshot still closes positions after an omitted response before the apply job" do
    source = create_simplefin_account("sf_delayed_empty", "Crypto", "investment", 200)
    account = accounts(:crypto)
    account.update!(simplefin_account_id: source.id)
    provider = source.ensure_account_provider!
    security = Security.create!(ticker: "CUSTOM:DELAYED", name: "Delayed position")
    account.holdings.create!(account_provider: provider, security: security, date: Date.yesterday,
      qty: 2, amount: 200, price: 100, currency: "USD")
    source.update!(raw_holdings_payload: [ { "id" => "position" } ])
    payload = { id: source.account_id, name: source.name, currency: "USD", balance: "200" }

    @importer.send(:import_account, payload.merge(holdings: []))
    @importer.send(:import_account, payload)
    perform_enqueued_jobs(only: SimplefinHoldingsApplyJob)

    assert_empty account.current_holdings
    assert_equal 0, account.holdings.find_by!(account_provider: provider, date: Date.current).qty
    assert_equal 200, account.reload.cash_balance
  end

  test "balances-only import persists a negative provider credit-card debt as positive" do
    credit_card = accounts(:credit_card)
    simplefin_account = create_simplefin_account("sf_amex_1", "Amex", "credit", -1911.72)
    credit_card.update!(simplefin_account_id: simplefin_account.id)

    @importer.send(:import_account_minimal_and_balance, {
      id: simplefin_account.account_id,
      name: "Amex",
      balance: -1911.72,
      currency: "USD"
    })

    assert_equal 1911.72, credit_card.reload.balance
    assert_equal 1911.72, credit_card.cash_balance
  end

  test "balances-only import honors a credit balance sign override" do
    credit_card = accounts(:credit_card)
    simplefin_account = create_simplefin_account("sf_credit_override_1", "Store Card", "credit", -48.48)
    simplefin_account.update!(balance_sign_override: "credit")
    credit_card.update!(simplefin_account_id: simplefin_account.id)

    @importer.send(:import_account_minimal_and_balance, {
      id: simplefin_account.account_id,
      name: "Store Card",
      balance: -48.48,
      currency: "USD"
    })

    assert_equal(-48.48, credit_card.reload.balance)
    assert_equal(-48.48, credit_card.cash_balance)
  end

  test "balances-only import honors a debt balance sign override" do
    credit_card = accounts(:credit_card)
    simplefin_account = create_simplefin_account("sf_debt_override_1", "Store Card", "credit", 48.48)
    simplefin_account.update!(balance_sign_override: "debt")
    credit_card.update!(simplefin_account_id: simplefin_account.id)

    @importer.send(:import_account_minimal_and_balance, {
      id: simplefin_account.account_id,
      name: "Store Card",
      balance: 48.48,
      currency: "USD"
    })

    assert_equal 48.48, credit_card.reload.balance
    assert_equal 48.48, credit_card.cash_balance
  end

  test "balances-only import keeps a positive loan principal positive" do
    loan = accounts(:loan)
    simplefin_account = create_simplefin_account("sf_loan_1", "Mortgage Loan", "loan", 250_000)
    loan.update!(simplefin_account_id: simplefin_account.id)

    @importer.send(:import_account_minimal_and_balance, {
      id: simplefin_account.account_id,
      name: "Mortgage Loan",
      balance: 250_000,
      currency: "USD"
    })

    assert_equal 250_000, loan.reload.balance
    assert_equal 250_000, loan.cash_balance
  end

  test "balances-only import keeps an explicit zero credit-card balance at zero" do
    credit_card = accounts(:credit_card)
    simplefin_account = create_simplefin_account("sf_card_zero_1", "Paid Off Card", "credit", 0)
    credit_card.update!(simplefin_account_id: simplefin_account.id)

    @importer.send(:import_account_minimal_and_balance, {
      id: simplefin_account.account_id,
      name: "Paid Off Card",
      balance: 0,
      "available-balance": 5_000,
      currency: "USD"
    })

    assert_equal 0, credit_card.reload.balance
    assert_equal 0, credit_card.cash_balance
  end

  test "balances-only import preserves a linked depository type over a liability inference" do
    depository = accounts(:depository)
    simplefin_account = create_simplefin_account("sf_linked_depository_1", "Mortgage Loan", "loan", 1_000)
    depository.update!(simplefin_account_id: simplefin_account.id)

    @importer.send(:import_account_minimal_and_balance, {
      id: simplefin_account.account_id,
      name: "Mortgage Loan",
      type: "loan",
      balance: 1_000,
      currency: "USD"
    })

    assert_equal 1_000, depository.reload.balance
    assert_equal 1_000, depository.cash_balance
  end

  # Both steps read every provider's flag and decide "pending" the same way, so
  # the sync must count for review before it excludes: run through their one
  # caller and the stale Lunch Flow entry is reported and then excluded, rather
  # than excluded by the first step and invisible to the second. Swap the two
  # calls and stale_unmatched_pending goes to nil here.
  test "stale pending review counts every provider's flag before the exclusion hides it" do
    account = @family.accounts.create!(name: "Stale pending", balance: 0, currency: "USD", accountable: Depository.new)
    create_pending_entry(account, "simplefin_maybe", "simplefin", "maybe", 10)
    create_pending_entry(account, "simplefin_false", "simplefin", "off", 11)
    create_pending_entry(account, "lunchflow_pending", "lunchflow", true, 12)

    @importer.send(:review_and_exclude_stale_pending, account)

    stats = @importer.send(:stats)
    assert_equal 2, stats["stale_unmatched_pending"]
    assert_equal 2, stats["stale_pending_excluded"]
    assert_empty stats.fetch("reconciliation_errors", [])
    assert_equal [ "simplefin_false" ], account.entries.where(excluded: false).pluck(:name)
  end

  test "a rejected access URL marks the item for reconnection and logs it" do
    provider = mock
    provider.expects(:get_accounts).raises(
      Provider::Simplefin::SimplefinError.new("SimpleFIN URL points to a disallowed network address", :invalid_url)
    )
    importer = SimplefinItem::Importer.new(@item, simplefin_provider: provider)

    assert_difference -> { DebugLogEntry.where(provider_key: "simplefin", family: @family).count }, 1 do
      assert_raises(Provider::Simplefin::SimplefinError) do
        importer.send(:fetch_accounts_data, start_date: nil, pending: false)
      end
    end

    assert @item.reload.requires_update?
  end

  test "a protocol v2 account takes its institution from the matching connection" do
    provider = mock
    provider.expects(:get_accounts).returns(
      connections: [
        { conn_id: "CON-other", name: "Other Bank", org_name: "Other Bank" },
        { conn_id: "CON-schwab", name: "Charles Schwab US", org_id: "mx.69378", org_name: "Charles Schwab US",
          org_url: "https://client.schwab.com/", sfin_url: "https://beta-bridge.simplefin.org/simplefin" }
      ],
      accounts: [ { id: "sf_brokerage_v2", name: "Brokerage ...123", conn_id: "CON-schwab", currency: "USD", balance: "1000" } ]
    )

    SimplefinItem::Importer.new(@item, simplefin_provider: provider).import_balances_only

    simplefin_account = @item.simplefin_accounts.find_by!(account_id: "sf_brokerage_v2")
    assert_equal(
      { "id" => "mx.69378", "name" => "Charles Schwab US", "url" => "https://client.schwab.com/",
        "sfin-url" => "https://beta-bridge.simplefin.org/simplefin" },
      simplefin_account.org_data
    )
    assert SimplefinAccount::Investments::HoldingsProcessor.new(simplefin_account).send(:institution_reports_total_basis?)
  end

  test "an account that already has an org keeps it" do
    provider = mock
    provider.expects(:get_accounts).returns(
      connections: [ { conn_id: "CON-1", name: "Connection Name", org_name: "Connection Org" } ],
      accounts: [ { id: "sf_v1_org", name: "Checking", conn_id: "CON-1", org: { name: "Account Org", domain: "bank.example" },
                    currency: "USD", balance: "10" } ]
    )

    SimplefinItem::Importer.new(@item, simplefin_provider: provider).import_balances_only

    assert_equal({ "name" => "Account Org", "domain" => "bank.example" },
                 @item.simplefin_accounts.find_by!(account_id: "sf_v1_org").org_data)
  end

  test "a regular sync after a long gap splits the range into requests the Bridge accepts" do
    travel_to Time.zone.parse("2026-11-07 12:00") do
      @item.stubs(:last_synced_at).returns(100.days.ago)
      provider, ranges = recording_provider

      SimplefinItem::Importer.new(@item, simplefin_provider: provider).send(:import_regular_sync)

      assert_equal 3, ranges.size
      assert_equal 130.days.ago, ranges.first.first
      assert_equal Time.current, ranges.last.last
      ranges.each { |from, to| assert_operator to - from, :<=, 45.days }
      ranges.each_cons(2) { |(_, previous_end), (next_start, _)| assert_equal previous_end, next_start }

      log = DebugLogEntry.find_by!(provider_key: "simplefin", source: "SimplefinItem::Importer")
      assert_equal 3, log.metadata["requests"]
    end
  end

  test "a regular sync keeps the transactions from every request" do
    travel_to Time.zone.parse("2026-11-07 12:00") do
      @item.stubs(:last_synced_at).returns(100.days.ago)
      simplefin_account = link_simplefin_account("sf_windows_1")
      provider, ranges = recording_provider(account_id: "sf_windows_1")

      SimplefinItem::Importer.new(@item, simplefin_provider: provider).send(:import_regular_sync)

      imported = simplefin_account.reload.raw_transactions_payload.map { |tx| tx["id"] }
      assert_equal 3, imported.size
      assert_equal ranges.map { |from, _| "tx_#{from.to_i}" }.sort, imported.sort
    end
  end

  test "a regular sync does not reach back more than a year" do
    travel_to Time.zone.parse("2026-11-07 12:00") do
      @item.stubs(:last_synced_at).returns(500.days.ago)
      provider, ranges = recording_provider

      SimplefinItem::Importer.new(@item, simplefin_provider: provider).send(:import_regular_sync)

      assert_equal 1.year.ago.beginning_of_day, ranges.first.first
      assert_equal Time.current, ranges.last.last
    end
  end

  test "the chunked history import keeps every request within the Bridge limit" do
    travel_to Time.zone.parse("2026-11-07 12:00") do
      @item.stubs(:sync_start_date).returns(100.days.ago.to_date)
      link_simplefin_account("sf_history_1")
      provider, ranges = recording_provider(account_id: "sf_history_1")

      SimplefinItem::Importer.new(@item, simplefin_provider: provider).send(:import_with_chunked_history)

      # Every chunk adds a transaction, so the import walks the whole range,
      # ending with a clipped 10-day chunk.
      assert_equal 3, ranges.size
      assert_equal 100.days.ago.beginning_of_day, ranges.last.first
      ranges.each { |from, to| assert_operator to - from, :<=, 45.days }
    end
  end

  test "the chunked history import looks at least 120 days back before giving up on an empty account" do
    provider, ranges = recording_provider

    SimplefinItem::Importer.new(@item, simplefin_provider: provider).send(:import_with_chunked_history)

    assert_operator ranges.first.last - ranges.last.first, :>=, 120.days
  end

  private

    # A provider that records each dated request's range. Without an account_id
    # it returns no accounts; with one, it returns that account with one new
    # transaction inside each dated request.
    def recording_provider(account_id: nil)
      ranges = []
      provider = Object.new
      provider.define_singleton_method(:get_accounts) do |_access_url, start_date: nil, end_date: nil, pending: nil|
        ranges << [ start_date, end_date ] if start_date
        next { accounts: [] } unless account_id

        transactions = []
        if start_date
          transactions << { id: "tx_#{start_date.to_i}", posted: (start_date + 1.day).to_i,
                            amount: "-5.00", description: "Coffee", payee: "Coffee" }
        end
        { accounts: [ { id: account_id, name: "Checking", currency: "USD", balance: "100.00",
                        "balance-date": Time.current.to_i, transactions: transactions } ] }
      end
      [ provider, ranges ]
    end

    def link_simplefin_account(account_id)
      simplefin_account = create_simplefin_account(account_id, "Checking", "checking", 100)
      accounts(:depository).update!(simplefin_account_id: simplefin_account.id)
      simplefin_account
    end

    def create_pending_entry(account, name, provider, pending, amount)
      account.entries.create!(
        name: name, date: 10.days.ago.to_date, amount: amount, currency: "USD",
        entryable: Transaction.new(extra: { provider => { "pending" => pending } })
      )
    end

    def create_simplefin_account(account_id, name, account_type, current_balance)
      @item.simplefin_accounts.create!(
        name: name,
        account_id: account_id,
        account_type: account_type,
        currency: "USD",
        current_balance: current_balance
      )
    end
end
