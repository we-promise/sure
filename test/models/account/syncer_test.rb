require "test_helper"
require "ostruct"

class Account::SyncerTest < ActiveSupport::TestCase
  test "post-sync auto matches only transfers touching the synced account" do
    account = accounts(:depository)

    account.family.expects(:auto_match_transfers!).with(account: account).once

    Account::Syncer.new(account).perform_post_sync
  end

  test "applies IBKR historical balance overrides after materialization" do
    family = families(:empty)
    account = family.accounts.create!(
      name: "IBKR Brokerage",
      balance: 0,
      cash_balance: 0,
      currency: "CHF",
      accountable: Investment.new(subtype: "brokerage")
    )
    ibkr_account = family.ibkr_items.create!(
      name: "IBKR",
      query_id: "QUERY123",
      token: "TOKEN123"
    ).ibkr_accounts.create!(
      name: "Main",
      ibkr_account_id: "U1234567",
      currency: "CHF"
    )
    ibkr_account.ensure_account_provider!(account)

    Account::MarketDataImporter.any_instance.expects(:import_all).once
    Balance::Materializer.any_instance.expects(:materialize_balances).once
    IbkrAccount::HistoricalBalancesSync.any_instance.expects(:sync!).once

    Account::Syncer.new(account).perform_sync(OpenStruct.new(window_start_date: nil))
  end

  # A provider that dates its holdings itself, but anchors the balance on the
  # day of the sync, leaves the two a day apart and the gap reads as cash.
  # Nothing fails, so the sync is the one place it can be seen.
  test "warns once when the balance anchor is dated away from the newest provider holding" do
    account, account_provider = linked_investment_account
    account.set_current_balance(1000, date: Date.current, schedule_sync: false)
    provider_holding(account, account_provider, date: Date.current - 1)

    assert_difference "DebugLogEntry.count", 1 do
      run_sync(account)
    end

    entry = DebugLogEntry.order(:created_at).last
    assert_equal "provider_sync", entry.category
    assert_equal "warn", entry.level
    assert_equal "Account::Syncer", entry.source
    assert_equal "ibkr", entry.provider_key
    assert_equal account, entry.account
    assert_equal account_provider, entry.account_provider
    assert_equal Date.current.to_s, entry.metadata["anchor_date"]
    assert_equal (Date.current - 1).to_s, entry.metadata["holdings_date"]
    assert_equal 1, entry.metadata["gap_days"]
    assert_match(/1 day\(s\) after/, entry.message)

    # The next day both dates have moved on and the gap has not: the shift is
    # already on record, whatever the dates now read.
    account.set_current_balance(1000, date: Date.current + 1, schedule_sync: false)
    provider_holding(account, account_provider, date: Date.current)
    assert_no_difference "DebugLogEntry.count" do
      run_sync(Account.find(account.id))
    end

    # A different gap is a new finding.
    account.set_current_balance(1000, date: Date.current + 3, schedule_sync: false)
    assert_difference "DebugLogEntry.count", 1 do
      run_sync(Account.find(account.id))
    end
    assert_equal 3, DebugLogEntry.order(:created_at).last.metadata["gap_days"]
  end

  test "stays quiet when the anchor and the newest provider holding share a date" do
    account, account_provider = linked_investment_account
    account.set_current_balance(1000, date: Date.current - 1, schedule_sync: false)
    provider_holding(account, account_provider, date: Date.current - 1)

    assert_no_difference "DebugLogEntry.count" do
      run_sync(account)
    end
  end

  test "stays quiet without provider-dated holdings or without an anchor" do
    account, account_provider = linked_investment_account

    # An anchor and only materialized holdings, which carry no provider.
    account.set_current_balance(1000, date: Date.current, schedule_sync: false)
    account.holdings.create!(security: securities(:aapl), qty: 1, price: 10, amount: 10, currency: "CHF", date: Date.current - 1)
    assert_no_difference "DebugLogEntry.count" do
      run_sync(account)
    end

    # Provider holdings and no anchor yet.
    unanchored, unanchored_provider = linked_investment_account
    provider_holding(unanchored, unanchored_provider, date: Date.current - 1)
    assert_no_difference "DebugLogEntry.count" do
      run_sync(unanchored)
    end
  end

  private
    def linked_investment_account
      family = families(:empty)
      account = family.accounts.create!(
        name: "IBKR Brokerage",
        balance: 0,
        cash_balance: 0,
        currency: "CHF",
        accountable: Investment.new(subtype: "brokerage")
      )
      ibkr_account = family.ibkr_items.create!(name: "IBKR", query_id: "QUERY123", token: "TOKEN123")
        .ibkr_accounts.create!(name: "Main", ibkr_account_id: "U1234567", currency: "CHF")
      ibkr_account.ensure_account_provider!(account)
      [ account, account.account_providers.first ]
    end

    def provider_holding(account, account_provider, date:)
      account.holdings.create!(
        security: securities(:aapl), qty: 1, price: 10, amount: 10, currency: "CHF",
        date: date, account_provider_id: account_provider.id
      )
    end

    def run_sync(account)
      Account::MarketDataImporter.any_instance.stubs(:import_all)
      Balance::Materializer.any_instance.stubs(:materialize_balances)
      IbkrAccount::HistoricalBalancesSync.any_instance.stubs(:sync!)
      Account::Syncer.new(account).perform_sync(OpenStruct.new(window_start_date: nil))
    end
end
