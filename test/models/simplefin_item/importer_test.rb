require "test_helper"

class SimplefinItem::ImporterTest < ActiveSupport::TestCase
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
